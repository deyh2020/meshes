// meshes/gpu/fwdprop.cu
// Ryan Hamerly, 4/3/21
//
// Implements the foward-propagation function fwdprop_N[64*K](), where [64*K] is the mesh size.  Requires the following
// preprocessor directives:
//   K  [int] = size/32.  Each thread manages 2*K waveguides.
//   L0 [int] = number of layers natively supported.  Limited by smem.  If L > L0, the propagation is broken into steps.
//   nL [int] = a total of nL*L0 shifts/lens are pre-loaded.  Must be even.  Tradeoff between smem space and gmem latency.
//   fname    = name of function (should be fwdprop_N[64*K])
//
// History:
//   04/03/21: Created this file.  First working CUDA code.
//   04/05/21: Moved the global memory I/O stuff to its own macros in gmem.cu.
//   05/17/21: Shortened and simplified, merging the 3 crossing types.


#define L_ker (L0)  // Actual number of layers stored in the kernel = L0
#define L_preload (L0*nL)  // Number of shifts / lens pre-loaded.

#if   CROSSING_TYPE == MZI
    #define stride_T  4
    #define define_T  __shared__ complex64 T[L0][4*K][32]
    #define load_u    load_u_mzi(u, u_in)
    #define load_T    load_T_mzi
    #define save_u    save_u_mzi(u, u_out)
    #define matmult   matmult_mzi
    #define scalar    complex64
#elif CROSSING_TYPE == SYM
    #define stride_T  3
    #define define_T  __shared__ float T[L0][3*K][32]
    #define load_u    load_u_sym(u, u_in)
    #define load_T    load_T_sym
    #define save_u    save_u_sym(u, u_out)
    #define matmult   matmult_sym
    #define scalar    complex64
#else
    #define stride_T  2
    #define define_T  __shared__ float T[L0][2*K][32]
    #define load_u    load_u_orth(u, u_in)
    #define load_T    load_T_orth
    #define save_u    save_u_orth(u, u_out)
    #define matmult   matmult_orth
    #define scalar    float
#endif


__global__ void fname(int N, int L, int B, int *lens, int *shifts, 
                      float *p, int ldp, float *s, int lds, 
                      scalar *u_in, scalar *u_out, int ldu, int mode)
{
    // Definitions and Initializations.
	u_in  += ldu * (blockDim.y*blockIdx.x + threadIdx.y);       // Pointer shift, one warp per instance.
	u_out += ldu * (blockDim.y*blockIdx.x + threadIdx.y);
    int b = (blockDim.y*(1 + blockIdx.x) < B) ? (blockDim.y) : (B - blockDim.y*blockIdx.x);     // # active warps
    define_T;                                                   // Transfer matrix T[L0][s*K][32]
    __shared__ int shifts_cache[nL*L0], lens_cache[nL*L0];      // Cache of lengths, shifts.
    scalar u[2*K];                                              // State.  The i^th waveguide is u[i%K] of thread i/K.
    load_u;                                                     // Load u, gmem -> smem [macro: gmem.cu].

    // Propagate fields through the mesh.
    for (int x = 0; x < L; x += L_ker)
    {
        int L_blk = (L_ker < L-x) ? L_ker : L-x;                // Layers in block = min(L0, L-x)
        load_pos_cache_fwd;                                     // Occasionally reload cache of shifts / lengths.
        load_T;                                                 // Load transfer matrices [macro: gmem.cu].

        for (int l = 0; l < L_blk; l++)                         // Iterate through L_blk layers.
        {
            scalar temp, u_2k;
            if (shifts_cache[(x+l) % L_preload] % 2)            // Misaligned MZIs: need warp shuffle.
            {
                for (int i = 0; i < K-1; i++)                   // Couple (u[1], u[2]), ..., (u[2K-3], u[2K-2])
                    matmult(&T[l][stride_T*i][threadIdx.x], u[2*i+1], u[2*i+2], temp, true);
                u_2k = __shfl_down_sync(0xffffffffu, u[0], 1, 32);  // Couple (u[2K-1], u[0]) with warp shuffle.
                matmult(&T[l][stride_T*K-stride_T][threadIdx.x], u[2*K-1], u_2k, temp, threadIdx.x != 31);
                u_2k = __shfl_up_sync(0xffffffffu, u_2k, 1, 32);
                if (threadIdx.x)
                    u[0] = u_2k;
            }
            else                                                // Aligned MZIs.  Easy case!
            {
                for (int i = 0; i < K; i++)                     // Couple (u[0], u[1]), ... (u[2K-2], u[2K-1]).
                    matmult(&T[l][stride_T*i][threadIdx.x], u[2*i], u[2*i+1], temp, true);
            }
        }
        
        p += L_ker * ldp;
        if (s) {s += L_ker * lds;}
        __syncthreads();
    }

	// Write data to output [macro: gmem.cu].
    save_u;
}


#undef L_ker
#undef L_preload
#undef K
#undef L0
#undef nL
#undef fname
#undef stride_T
#undef define_T
#undef load_u
#undef load_T
#undef save_u
#undef matmult
#undef scalar