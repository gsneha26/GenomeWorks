/*
* Copyright 2020 NVIDIA CORPORATION.
*
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
*     http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
*/

#include "chainer_utils.cuh"

#include <fstream>
#include <sstream>
#include <cstdlib>

// Needed for accumulate - remove when ported to cuda
#include <numeric>
#include <limits>

#include <cub/cub.cuh>
#include <thrust/execution_policy.h>

#include <claraparabricks/genomeworks/utils/cudautils.hpp>

namespace claraparabricks
{

namespace genomeworks
{

namespace cudamapper
{
namespace chainerutils
{

__host__ __device__ Overlap create_simple_overlap(const Anchor& start, const Anchor& end, const int32_t num_anchors)
{
    Overlap overlap;
    overlap.num_residues_ = num_anchors;

    overlap.query_read_id_  = start.query_read_id_;
    overlap.target_read_id_ = start.target_read_id_;
    assert(start.query_read_id_ == end.query_read_id_ && start.target_read_id_ == end.target_read_id_);

    overlap.query_start_position_in_read_ = min(start.query_position_in_read_, end.query_position_in_read_);
    overlap.query_end_position_in_read_   = max(start.query_position_in_read_, end.query_position_in_read_);
    bool is_negative_strand               = end.target_position_in_read_ < start.target_position_in_read_;
    if (is_negative_strand)
    {
        overlap.relative_strand                = RelativeStrand::Reverse;
        overlap.target_start_position_in_read_ = end.target_position_in_read_;
        overlap.target_end_position_in_read_   = start.target_position_in_read_;
    }
    else
    {
        overlap.relative_strand                = RelativeStrand::Forward;
        overlap.target_start_position_in_read_ = start.target_position_in_read_;
        overlap.target_end_position_in_read_   = end.target_position_in_read_;
    }
    return overlap;
}

void allocate_anchor_chains(device_buffer<Overlap>& overlaps,
                            device_buffer<int32_t>& unrolled_anchor_chains,
                            device_buffer<int32_t>& anchor_chain_starts,
                            int32_t num_overlaps,
                            int32_t& num_total_anchors,
                            DefaultDeviceAllocator& _allocator,
                            cudaStream_t& _cuda_stream)
{
    // sum the number of chains across all overlaps
    device_buffer<char> d_temp_buf(_allocator, _cuda_stream);
    void* d_temp_storage           = nullptr;
    std::size_t temp_storage_bytes = 0;
    OverlapToNumResiduesOp overlap_residue_count_op;
    cub::TransformInputIterator<int32_t, OverlapToNumResiduesOp, Overlap*> d_residue_counts(overlaps.data(), overlap_residue_count_op);

    device_buffer<int32_t> d_num_total_anchors(1, _allocator, _cuda_stream);

    cub::DeviceReduce::Sum(d_temp_storage,
                           temp_storage_bytes,
                           d_residue_counts,
                           d_num_total_anchors.data(),
                           num_overlaps,
                           _cuda_stream);

    d_temp_buf.clear_and_resize(temp_storage_bytes);
    d_temp_storage = d_temp_buf.data();

    cub::DeviceReduce::Sum(d_temp_storage,
                           temp_storage_bytes,
                           d_residue_counts,
                           d_num_total_anchors.data(),
                           num_overlaps,
                           _cuda_stream);

    d_temp_storage     = nullptr;
    temp_storage_bytes = 0;

    num_total_anchors = cudautils::get_value_from_device(d_num_total_anchors.data(), _cuda_stream);

    unrolled_anchor_chains.clear_and_resize(num_total_anchors);
    anchor_chain_starts.clear_and_resize(num_overlaps);

    cub::DeviceScan::ExclusiveSum(d_temp_storage,
                                  temp_storage_bytes,
                                  d_residue_counts,
                                  anchor_chain_starts.data(),
                                  num_overlaps,
                                  _cuda_stream);

    d_temp_buf.clear_and_resize(temp_storage_bytes);
    d_temp_storage = d_temp_buf.data();

    cub::DeviceScan::ExclusiveSum(d_temp_storage,
                                  temp_storage_bytes,
                                  d_residue_counts,
                                  anchor_chain_starts.data(),
                                  num_overlaps,
                                  _cuda_stream);
}

__global__ void output_overlap_chains_by_RLE(const Overlap* overlaps,
                                             const Anchor* anchors,
                                             const int32_t* chain_starts,
                                             const int32_t* chain_lengths,
                                             int32_t* anchor_chains,
                                             int32_t* anchor_chain_starts,
                                             int32_t num_overlaps)
{
    int32_t d_thread_id = blockIdx.x * blockDim.x + threadIdx.x;
    int32_t stride      = blockDim.x * gridDim.x;
    for (int i = d_thread_id; i < num_overlaps; i += stride)
    {
        int32_t chain_start  = chain_starts[i];
        int32_t chain_length = chain_lengths[i];
        for (int32_t ind = chain_start; ind < chain_start + chain_length; ++i)
        {
            anchor_chains[ind] = ind;
        }
    }
}

__global__ void output_overlap_chains_by_backtrace(const Overlap* overlaps,
                                                   const Anchor* anchors,
                                                   const bool* select_mask,
                                                   const int32_t* predecessors,
                                                   int32_t* anchor_chains,
                                                   int32_t* anchor_chain_starts,
                                                   int32_t num_overlaps,
                                                   bool check_mask)
{
    int32_t d_thread_id = blockIdx.x * blockDim.x + threadIdx.x;
    int32_t stride      = blockDim.x * gridDim.x;

    // Processes one overlap per iteration,
    // "i" corresponds to an overlap
    for (int i = d_thread_id; i < num_overlaps; i += stride)
    {
        // index within this chain of anchors (i.e., the anchors within a single overlap)

        if (!check_mask || (check_mask & select_mask[i]))
        {
            int32_t anchor_chain_index = 0;
            // As chaining proceeds backwards (i.e., it's a backtrace),
            // we need to fill the new anchor chain array in in reverse order.
            int32_t index = anchor_chain_starts[i];
            while (index != -1)
            {
                anchor_chains[anchor_chain_starts[i] + (overlaps[i].num_residues_ - anchor_chain_index)] = index;
                int32_t pred                                                                             = predecessors[index];
                index                                                                                    = pred;
                ++anchor_chain_index;
            }
        }
    }
}

__global__ void backtrace_anchors_to_overlaps(const Anchor* anchors,
                                              Overlap* overlaps,
                                              double* scores,
                                              bool* max_select_mask,
                                              int32_t* predecessors,
                                              const int32_t n_anchors,
                                              const int32_t min_score)
{
    const std::size_t d_tid = blockIdx.x * blockDim.x + threadIdx.x;
    if (d_tid < n_anchors)
    {

        int32_t global_overlap_index = d_tid;
        if (scores[d_tid] >= min_score)
        {

            int32_t index                = global_overlap_index;
            int32_t first_index          = index;
            int32_t num_anchors_in_chain = 0;
            Anchor final_anchor          = anchors[global_overlap_index];

            while (index != -1)
            {
                first_index  = index;
                int32_t pred = predecessors[index];
                if (pred != -1)
                {
                    max_select_mask[pred] = false;
                }
                num_anchors_in_chain++;
                index = predecessors[index];
            }
            Anchor first_anchor            = anchors[first_index];
            overlaps[global_overlap_index] = create_simple_overlap(first_anchor, final_anchor, num_anchors_in_chain);
        }
        else
        {
            max_select_mask[global_overlap_index] = false;
        }
    }
}

} // namespace chainerutils
} // namespace cudamapper
} // namespace genomeworks
} // namespace claraparabricks