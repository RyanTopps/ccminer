extern "C" {
#include "sph/sph_blake.h"
#include "sph/sph_bmw.h"
#include "sph/sph_skein.h"
#include "sph/sph_keccak.h"
#include "sph/sph_cubehash.h"
#include "lyra2/Lyra2.h"
}

#include "miner.h"
#include "cuda_helper.h"


static _ALIGN(64) uint64_t *d_hash[MAX_GPUS];
static uint64_t* d_matrix[MAX_GPUS];

extern void blake256_cpu_init(int thr_id, uint32_t threads);
extern void blake256_cpu_hash_80(const int thr_id, const uint32_t threads, const uint32_t startNonce, uint64_t *Hash, int order);
extern void blake256_cpu_setBlock_80(uint32_t *pdata);
extern void keccak256_cpu_hash_32(int thr_id, uint32_t threads, uint32_t startNonce, uint64_t *d_outputHash, int order);
extern void keccak256_cpu_init(int thr_id, uint32_t threads);
extern void keccak256_cpu_free(int thr_id);
extern void skein256_cpu_hash_32(int thr_id, uint32_t threads, uint32_t startNonce, uint64_t *d_outputHash, int order);
extern void skein256_cpu_init(int thr_id, uint32_t threads);
extern void cubehash256_cpu_hash_32(int thr_id, uint32_t threads, uint32_t startNounce, uint64_t *d_hash, int order);

extern void lyra2v2_cpu_hash_32(int thr_id, uint32_t threads, uint32_t startNonce, uint64_t *d_outputHash, int order);
extern void lyra2v2_cpu_init(int thr_id, uint32_t threads, uint64_t* d_matrix);

extern void bmw256_setTarget(const void *ptarget);
extern void bmw256_cpu_init(int thr_id, uint32_t threads);
extern void bmw256_cpu_free(int thr_id);
extern void bmw256_cpu_hash_32(int thr_id, uint32_t threads, uint32_t startNounce, uint64_t *g_hash, uint32_t *resultnonces);

void lyra2v2_hash(void *state, const void *input)
{
	uint32_t hashA[8], hashB[8];

	sph_blake256_context      ctx_blake;
	sph_keccak256_context     ctx_keccak;
	sph_skein256_context      ctx_skein;
	sph_bmw256_context        ctx_bmw;
	sph_cubehash256_context   ctx_cube;

	sph_blake256_init(&ctx_blake);
	sph_blake256(&ctx_blake, input, 80);
	sph_blake256_close(&ctx_blake, hashA);

	sph_keccak256_init(&ctx_keccak);
	sph_keccak256(&ctx_keccak, hashA, 32);
	sph_keccak256_close(&ctx_keccak, hashB);

	sph_cubehash256_init(&ctx_cube);
	sph_cubehash256(&ctx_cube, hashB, 32);
	sph_cubehash256_close(&ctx_cube, hashA);

	LYRA2(hashB, 32, hashA, 32, hashA, 32, 1, 4, 4);

	sph_skein256_init(&ctx_skein);
	sph_skein256(&ctx_skein, hashB, 32);
	sph_skein256_close(&ctx_skein, hashA);

	sph_cubehash256_init(&ctx_cube);
	sph_cubehash256(&ctx_cube, hashA, 32);
	sph_cubehash256_close(&ctx_cube, hashB);

	sph_bmw256_init(&ctx_bmw);
	sph_bmw256(&ctx_bmw, hashB, 32);
	sph_bmw256_close(&ctx_bmw, hashA);

	memcpy(state, hashA, 32);
}

static bool init[MAX_GPUS] = { 0 };

extern "C" int scanhash_lyra2v2(int thr_id, struct work* work, uint32_t max_nonce, unsigned long *hashes_done)
{
	uint32_t *pdata = work->data;
	uint32_t *ptarget = work->target;
	const uint32_t first_nonce = pdata[19];
	int dev_id = device_map[thr_id];
	int intensity = (device_sm[dev_id] > 500 && !is_windows()) ? 20 : 18;
	unsigned int defthr = 1U << intensity;
	uint32_t throughput = device_intensity(dev_id, __func__, defthr);

	if (opt_benchmark)
		ptarget[7] = 0x00ff;

	if (!init[thr_id])
	{
		cudaSetDevice(dev_id);
		//cudaSetDeviceFlags(cudaDeviceScheduleBlockingSync);
		//if (opt_n_gputhreads == 1)
		//	cudaDeviceSetCacheConfig(cudaFuncCachePreferL1);
		cudaGetLastError();

		blake256_cpu_init(thr_id, throughput);
		keccak256_cpu_init(thr_id,throughput);
		skein256_cpu_init(thr_id, throughput);
		bmw256_cpu_init(thr_id, throughput);

		if (device_sm[device_map[thr_id]] < 300) {
			applog(LOG_ERR, "Device SM 3.0 or more recent required!");
			proper_exit(1);
			return -1;
		}

		// DMatrix (780Ti may prefer 16 instead of 12, cf djm34)
		CUDA_SAFE_CALL(cudaMalloc(&d_matrix[thr_id], (size_t)12 * sizeof(uint64_t) * 4 * 4 * throughput));
		lyra2v2_cpu_init(thr_id, throughput, d_matrix[thr_id]);

		CUDA_SAFE_CALL(cudaMalloc(&d_hash[thr_id], (size_t)32 * throughput));

		init[thr_id] = true;
	}

	uint32_t endiandata[20];
	for (int k=0; k < 20; k++)
		be32enc(&endiandata[k], ((uint32_t*)pdata)[k]);

	blake256_cpu_setBlock_80(pdata);
	bmw256_setTarget(ptarget);

	do {
		int order = 0;
		uint32_t foundNonces[2] = { 0, 0 };

		blake256_cpu_hash_80(thr_id, throughput, pdata[19], d_hash[thr_id], order++);
		keccak256_cpu_hash_32(thr_id, throughput, pdata[19], d_hash[thr_id], order++);
		cubehash256_cpu_hash_32(thr_id, throughput, pdata[19], d_hash[thr_id], order++);
		lyra2v2_cpu_hash_32(thr_id, throughput, pdata[19], d_hash[thr_id], order++);
		skein256_cpu_hash_32(thr_id, throughput, pdata[19], d_hash[thr_id], order++);
		cubehash256_cpu_hash_32(thr_id, throughput,pdata[19], d_hash[thr_id], order++);

		bmw256_cpu_hash_32(thr_id, throughput, pdata[19], d_hash[thr_id], foundNonces);

		*hashes_done = pdata[19] - first_nonce + throughput;

		if (foundNonces[0] != 0)
		{
			uint32_t vhash64[8];
			be32enc(&endiandata[19], foundNonces[0]);
			lyra2v2_hash(vhash64, endiandata);
			if (vhash64[7] <= ptarget[7] && fulltest(vhash64, ptarget))
			{
				int res = 1;
				work_set_target_ratio(work, vhash64);
				// check if there was another one...
				if (foundNonces[1] != 0)
				{
					be32enc(&endiandata[19], foundNonces[1]);
					lyra2v2_hash(vhash64, endiandata);
					if (bn_hash_target_ratio(vhash64, ptarget) > work->shareratio)
						work_set_target_ratio(work, vhash64);
					pdata[21] = foundNonces[1];
					res++;
				}
				pdata[19] = foundNonces[0];
				MyStreamSynchronize(NULL, 0, device_map[thr_id]);
				return res;
			}
			else
			{
				applog(LOG_WARNING, "GPU #%d: result does not validate on CPU!", dev_id);
			}
		}

		pdata[19] += throughput;

	} while (!work_restart[thr_id].restart && (max_nonce > ((uint64_t)(pdata[19]) + throughput)));

	*hashes_done = pdata[19] - first_nonce + 1;
	MyStreamSynchronize(NULL, 0, device_map[thr_id]);
	return 0;
}

// cleanup
extern "C" void free_lyra2v2(int thr_id)
{
	if (!init[thr_id])
		return;

	cudaSetDevice(device_map[thr_id]);

	cudaFree(d_hash[thr_id]);
	cudaFree(d_matrix[thr_id]);

	bmw256_cpu_free(thr_id);
	keccak256_cpu_free(thr_id);

	init[thr_id] = false;

	cudaDeviceSynchronize();
}
