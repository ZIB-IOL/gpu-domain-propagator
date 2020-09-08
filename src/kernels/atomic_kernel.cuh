#ifndef __GPUPROPAGATOR_ATOMICKERNEL_CUH__
#define __GPUPROPAGATOR_ATOMICKERNEL_CUH__

#include "../params.h"
#include "util_kernels.cuh"

template <typename datatype>
__global__ void GPUAtomicDomainPropagation
(
    const int n_cons,
    const int n_vars,
    const int max_n_cons_in_block,
    const int* col_indices,
    const int* row_ptrs,
    const int* row_blocks,
    const datatype* vals,
    datatype* lbs,
    datatype* ubs,
    const int* vartypes,
    const datatype* lhss,
    const datatype* rhss,
    bool* change_found
)
{
  // Launched with NNZ_PER_WG threads per block and NUM_BLOCKS blocks

  const int block_row_begin = row_blocks[blockIdx.x];
  const int block_row_end   = row_blocks[blockIdx.x + 1];
  const int nnz_in_block    = row_ptrs[block_row_end] - row_ptrs[block_row_begin];
  const int block_data_begin = row_ptrs[block_row_begin];

  __shared__ datatype cache_minacts[NNZ_PER_WG];
  __shared__ datatype cache_maxacts[NNZ_PER_WG];
  __shared__ datatype validx_considx_map[NNZ_PER_WG];

  extern __shared__ datatype shared_mem[]; // constains one array for minacts and another for maxacts

 // for usage with types different than double
 // extern __shared__ unsigned char my_shared_mem[];
 // datatype *shared_mem = reinterpret_cast<datatype *>(my_shared_mem);

  datatype* minacts = shared_mem;
  datatype* maxacts = &shared_mem[max_n_cons_in_block];

  datatype coeff;
  datatype lb;
  datatype ub;

  if (block_row_end - block_row_begin > 1) // if the block consists of more than 1 row in the matrix
  {

    /// CSR-Stream case
    const int thread_data_begin = block_data_begin + threadIdx.x;
    const int varidx = col_indices[thread_data_begin];

    // compute local contributions to activities
    if (threadIdx.x < nnz_in_block)
    {
        coeff = vals[thread_data_begin];
        lb = lbs[varidx];
        ub = ubs[varidx];
        cache_minacts[threadIdx.x] = coeff > 0? coeff*lb : coeff*ub; // minactivity
        cache_maxacts[threadIdx.x] = coeff > 0? coeff*ub : coeff*lb; // maxactivity
    }
    __syncthreads();

    // power of two less than or equal to NUM_THREADS / NUM_ROWS_IN_BLOCK
    const int threads_for_reduction = prev_power_of_2(blockDim.x / (block_row_end - block_row_begin));

    if (threads_for_reduction > 1)
    {
      /// Reduce all non zeroes of row by multiple threads
      const int thread_in_block = threadIdx.x % threads_for_reduction;
      const int local_row = block_row_begin + threadIdx.x / threads_for_reduction;

      datatype dot_minact = 0.0;
      datatype dot_maxact = 0.0;

      if (local_row < block_row_end)
      {
        const int local_first_element = row_ptrs[local_row] - block_data_begin;
        const int local_last_element = row_ptrs[local_row + 1] - block_data_begin;

        //#pragma unroll
        for (int local_element = local_first_element + thread_in_block;
              local_element < local_last_element;
              local_element += threads_for_reduction)
        {
          // The following line saves the map between the index i of the vals array and the constraint j the
          // element at index i belongs to. We need this to easily access data saved per row, such as lhs and rhs.
          validx_considx_map[local_element] = local_row;

          dot_minact += cache_minacts[local_element];
          dot_maxact += cache_maxacts[local_element];
        }
      }

      __syncthreads ();

      cache_minacts[threadIdx.x] = dot_minact;
      cache_maxacts[threadIdx.x] = dot_maxact;

      /// Now each row has threads_for_reduction values in cache_minacts
      //#pragma unroll
      for (int j = threads_for_reduction / 2; j > 0; j /= 2)
      {
        /// Reduce for each row
        __syncthreads ();

        const bool use_result = thread_in_block < j && threadIdx.x + j < NNZ_PER_WG;

        if (use_result)
        {
          dot_minact += cache_minacts[threadIdx.x + j];
          dot_maxact += cache_maxacts[threadIdx.x + j];
        }

        __syncthreads ();

        if (use_result)
        {
          cache_minacts[threadIdx.x] = dot_minact;
          cache_maxacts[threadIdx.x] = dot_maxact;
        }
      }

      if (thread_in_block == 0 && local_row < block_row_end)
      {
        minacts[local_row - block_row_begin] = dot_minact;
        maxacts[local_row - block_row_begin] = dot_maxact;
      }
    }
    else
    {
      /// Reduce all non zeroes of row by single thread
      int local_row = block_row_begin + threadIdx.x;
      const int local_first_element = row_ptrs[local_row] - block_data_begin;
      const int local_last_element = row_ptrs[local_row + 1] - block_data_begin;

      while (local_row < block_row_end)
      {
        datatype dot_minact = 0.0;
        datatype dot_maxact = 0.0;

        //#pragma unroll
        for (int local_element = local_first_element; local_element < local_last_element; local_element++)
        {
          // The following line saves the map between the index i of the vals array and the constraint j the
          // element at index i belongs to. We need this to easily access data saved per row, such as lhs and rhs.
          validx_considx_map[local_element] = local_row;

          dot_minact += cache_minacts[local_element];
          dot_maxact += cache_maxacts[local_element];
        }

        minacts[local_row - block_row_begin] = dot_minact;
        maxacts[local_row - block_row_begin] = dot_maxact;

        local_row += NNZ_PER_WG;
      }
    }

      // COMPUTING NEW BOUND CANDIDATES FOR CSR-SPARSE CASE
      __syncthreads();

      if (threadIdx.x < nnz_in_block)
      {
        // get the index of the constraint that the element threadIdx.x of the vals array belongs to
        int considx = validx_considx_map[threadIdx.x];

        datatype newlb;
        datatype newub;

        getNewBoundCandidates(
          lhss[considx],
          rhss[considx],
          coeff,
          minacts[considx - block_row_begin], // this is in shared memory - each block's indexing strats from 0, hence the need for - block row begin
          maxacts[considx - block_row_begin], // this is in shared memory - each block's indexing strats from 0, hence the need for - block row begin
          lb,
          ub,
          &newlb,
          &newub
        );

         bool isVarCont = vartypes[varidx] == 3;
         newub = isVarCont? newub : floor(newub);
         newlb = isVarCont? newlb : ceil(newlb);

         double oldub = atomicMin(&ubs[varidx], newub);
         double oldlb = atomicMax(&lbs[varidx], newlb);

         if (newub < oldub || newlb > oldlb)
            *change_found = true;
      }
  }
  else
  {
    const int block_data_end = row_ptrs[block_row_begin + 1];
    const int warp_id = threadIdx.x / WARP_SIZE;
    const int lane = threadIdx.x % WARP_SIZE;

    datatype dot_minact = 0;
    datatype dot_maxact = 0;

    // if nnz_in_block<=64, than computing this row with one warp is more efficient then using all the threads in the block
    if (nnz_in_block <= VECTOR_VS_VECTORL_NNZ_THRESHOLD || NNZ_PER_WG <= WARP_SIZE)
    {
      // printf("vector kernel, cons: %d\n", row);
      /// CSR-Vector case
      if (block_row_begin < n_cons)
      {

        //#pragma unroll
        for (int element = block_data_begin + lane; element < block_data_end; element += WARP_SIZE)
        {

            coeff = vals[element];
            lb = lbs[col_indices[element]];
            ub = ubs[col_indices[element]];

            dot_minact += coeff > 0? coeff*lb : coeff*ub; // minactivity
            dot_maxact += coeff > 0? coeff*ub : coeff*lb; // maxactivity
        }
      }

      dot_minact = warp_reduce_sum (dot_minact);
      dot_maxact = warp_reduce_sum (dot_maxact);

      if (lane == 0 && warp_id == 0 && block_row_begin < n_cons)
      {
        // this is in shared memory - each block's indexing strats from 0
        minacts[0] = dot_minact;
        maxacts[0] = dot_maxact;
      }
    }
    // If there is more than 64 nnz_in_block in the row, use all the threads in the block for the computation
    else
    {
      /// CSR-VectorL case
      if (block_row_begin < n_cons)
      {

        //#pragma unroll
        for (int element = block_data_begin + threadIdx.x; element < block_data_end; element += blockDim.x)
        {
            coeff = vals[element];
            lb = lbs[col_indices[element]];
            ub = ubs[col_indices[element]];

            dot_minact += coeff > 0? coeff*lb : coeff*ub; // minactivity
            dot_maxact += coeff > 0? coeff*ub : coeff*lb; // maxactivity
        }
      }

      dot_minact = warp_reduce_sum (dot_minact);
      dot_maxact = warp_reduce_sum (dot_maxact);

      if (lane == 0)
      {
        cache_minacts[warp_id] = dot_minact;
        cache_maxacts[warp_id] = dot_maxact;
      }
      __syncthreads ();

      if (warp_id == 0)
      {
        dot_minact = 0.0;
        dot_maxact = 0.0;

        //#pragma unroll
        for (int element = lane; element < blockDim.x / WARP_SIZE; element += WARP_SIZE)
        {
            dot_minact += cache_minacts[element];
            dot_maxact += cache_maxacts[element];
        }

        dot_minact = warp_reduce_sum (dot_minact);
        dot_maxact = warp_reduce_sum (dot_maxact);

        if (lane == 0 && block_row_begin < n_cons)
        {
            // this is in shared memory - each block's indexing strats from 0
            minacts[0] = dot_minact;
            maxacts[0] = dot_maxact;
        }
      }
    }

    __syncthreads();

    // START NEW BOUND COMPUTATION CODE

    if (block_row_begin < n_cons)
    {

      //#pragma unroll
      for (int element = block_data_begin + threadIdx.x; element < block_data_end; element += blockDim.x)
      {
          const int varidx = col_indices[element];
          datatype newlb;
          datatype newub;

          getNewBoundCandidates(
            lhss[block_row_begin],
            rhss[block_row_begin],
            vals[element],
            minacts[0], // this is in shared memory - each block's indexing strats from 0
            maxacts[0], // this is in shared memory - each block's indexing strats from 0
            lbs[col_indices[element]],
            ubs[col_indices[element]],
            &newlb,
            &newub
          );

         bool isVarCont = vartypes[varidx] == 3;
         newub = isVarCont? newub : floor(newub);
         newlb = isVarCont? newlb : ceil(newlb);

         double oldub = atomicMin(&ubs[varidx], newub);
         double oldlb = atomicMax(&lbs[varidx], newlb);

         if (newub < oldub || newlb > oldlb)
            *change_found = true;

      }  
    }
  }
}

template <typename datatype>
__global__ void GPUAtomicPropEntryKernel
(
    const int blocks_count,
    const int max_num_cons_in_block,
    const int n_cons,
    const int n_vars,
    const int max_n_cons_in_block,
    const int* col_indices,
    const int* row_ptrs,
    const int* row_blocks,
    const datatype* vals,
    datatype* lbs,
    datatype* ubs,
    const int* vartypes,
    const datatype* lhss,
    const datatype* rhss,
    bool* change_found
)
{
  int prop_round;

  for (prop_round=1; prop_round <= MAX_NUM_ROUNDS && *change_found; prop_round++)
  {
    *change_found = false;

    // shared memory layout:
    // - max_num_cons_in_block elems of type datatype for minactivities
    // - max_num_cons_in_block elems of type datatype for maxactivities
    GPUAtomicDomainPropagation<datatype> <<< blocks_count, NNZ_PER_WG, 2 * max_num_cons_in_block * sizeof(datatype) >>>
    (
        n_cons, n_vars, max_num_cons_in_block, col_indices, row_ptrs, row_blocks, vals, lbs, ubs, vartypes, lhss, rhss, change_found
    );

    cudaDeviceSynchronize();

  }

  VERBOSE_CALL( printf("Atomic GPU propagation done. num rounds: %d\n", prop_round) );
}

#endif