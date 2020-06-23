/*
 * Copyright (c) 2020, NVIDIA CORPORATION.
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

#include <text/subword/detail/cp_data.h>
#include <cudf/utilities/error.hpp>
#include <text/subword/detail/cp_data_vec.ah>
#include <text/subword/detail/hash_utils.cuh>
#include <text/subword/detail/tokenizer_utils.cuh>
#include <text/subword/detail/tokenizers.hpp>

#include <device_launch_parameters.h>
#include <cub/device/device_scan.cuh>
#include <cub/device/device_select.cuh>
#include <iostream>

namespace nvtext {
namespace detail {
namespace {
/**
 * @brief Writes the index to each thread which points to the start of a word to idx_for_sen_start.
 *
 * It is guaranteed that the same number of indices will be written to each
 * kernel and that after the select step, the two arrays will be aligned (ie.
 * `start_word_indices[word]` and `end_word_indices[word]` are the start and
 * end for the same word). This is not true before the cub::deviceselect is done.
 *
 * @param code_points A pointer to the code points in the sentence after being run through the basic
 *        tokenizer.
 * @param start_word_indices An array which will contain the starting index for each word scattered
 *        throughout. If an index does not represent a word start, the max uint32_t value is written
 *        to indicate this. A post processing step is required to select all the relevant values
 *        from this array.
 * @param end_word_indices An array which will contain the one past the end index for each word
 *        scattered throughout. If an index does not represent a word end, the max uint32_t value is
 *        written to indicate this. A post processing step is required to select all the relevant
 *        values from this array.
 * @param num_code_points The total number of code_points in the code_points array.
 * @param token_ids The array which will hold the token ids. This kernel initialized all values in
 *        this array to the max uint32_t. It is assumed that the length of this array is
 *        `num_code_points`.
 * @param tokens_per_word The array which will hold the number of tokens in each word. This kernel
 *         initialized all values in this array to 0. It is assumed that the length of this array is
 *         `num_code_points`.
 */
__global__ void init_data_and_mark_word_start_and_ends(uint32_t* code_points,
                                                       uint32_t* start_word_indices,
                                                       uint32_t* end_word_indices,
                                                       size_t num_code_points,
                                                       uint32_t* token_ids,
                                                       uint8_t* tokens_per_word)
{
  uint32_t char_for_thread = blockDim.x * blockIdx.x + threadIdx.x;

  // Deal with the start_word_indices array
  if (char_for_thread < num_code_points) {
    uint32_t val_to_write = std::numeric_limits<uint32_t>::max();
    if ((code_points[char_for_thread] != SPACE_CODE_POINT) && (char_for_thread > 0) &&
        (code_points[char_for_thread - 1] == SPACE_CODE_POINT)) {
      val_to_write = char_for_thread;
    }
    start_word_indices[char_for_thread] = val_to_write;

    // Deal with the end_word_indices_array
    val_to_write = std::numeric_limits<uint32_t>::max();
    if ((code_points[char_for_thread] != SPACE_CODE_POINT) &&
        (char_for_thread + 1 < num_code_points) &&
        (code_points[char_for_thread + 1] == SPACE_CODE_POINT)) {
      val_to_write = char_for_thread + 1;
    }
    end_word_indices[char_for_thread] = val_to_write;

    token_ids[char_for_thread]       = std::numeric_limits<uint32_t>::max();
    tokens_per_word[char_for_thread] = 0;
  }
}

/**
 * @brief Writes the indices of the characters that start and end sentences.
 *
 * This kernel should be called after `mark_word_start_and_ends` with at least `num_sentences` total
 * threads.
 *
 * It is guaranteed that the same number of indices will be written to each
 * kernel and that after the select step, the two arrays will be aligned (ie.
 * `start_word_indices[word]` and `end_word_indices[word]` are the start and
 * end for the same word). This is not true before the cub::deviceselect is done.
 *
 * @param code_points A pointer to the code points in the sentence after being run through the basic
 *        tokenizer.
 * @param sentence_offsets An array containing the index of the starting character of each sentence
 *        with an extra space at the end containing the total number of characters. As a result,
 *        this array is of length num_sentences + 1.
 * @param start_word_indices An array which will contain the starting index for each word scattered
 *        throughout. If an index does not represent a word start, the max-uint32_t value is written
 *        to indicate this.
 * @param end_word_indices An array which will contain the one past the end index for each word
 *        scattered throughout. If an index does not represent a word end, the max uint32_t value is
 *        written to indicate this.
 * @param num_sentences The total number of sentences to be processed.
 */
__global__ void mark_sentence_start_and_ends(uint32_t* code_points,
                                             uint32_t* sentence_offsets,
                                             uint32_t* start_word_indices,
                                             uint32_t* end_word_indices,
                                             uint32_t num_sentences)
{
  uint32_t char_for_thread = blockDim.x * blockIdx.x + threadIdx.x;
  // Ensure the starting character of each sentence is written to the word start array.
  if (char_for_thread <= num_sentences) {
    const uint32_t offset = sentence_offsets[char_for_thread];

    if ((char_for_thread < num_sentences) && (code_points[offset] != SPACE_CODE_POINT)) {
      start_word_indices[offset] = offset;
    }

    if ((char_for_thread > 0) && (code_points[offset - 1] != SPACE_CODE_POINT)) {
      end_word_indices[offset - 1] = offset;
    }
  }
}

/**
 * @brief Splits words into their token ids.
 *
 * Each thread is assigned a word to tokenize based on thread_to_word_map. Each thread tokenizes
 * its word and writes the number of tokens it found in the tokens_per_word array.
 *
 * The tokens_per_word array is kept to the length (num_code_points + 1). This means each thread
 * can write its number of tokens to the index in thread_to_word_map corresponding to the starting
 * character of each word. Since sentences must start at some word, we can prefix sum this array
 * and use the sentence_lengths code point offsets to directly index the number of tokens in each
 * sentence.
 *
 * The `token_ids` array should be initialized to the max uint32_t before calling this kernel.
 *
 * @param code_points An array containing all of the code points to be processed
 * @param hash_table An array containing the flattened hash table with key, value pairs
 *        packed in 64-bits
 * @param bin_coefficients A pointer to the GPU pointer containing the hashing parameters for
 *        each hash bin on the GPU.
 * @param bin_offsets: A pointer to the GPU pointer containing the start index of each bin in
 *        the flattened hash table.
 * @param token_ids The index for each token found during tokenization. This is of length
 *        num_code_points. In most cases, multiple characters will collapse to one token. In these
 *        cases, the max uint32_t will be in place. Cub will be used later to filter out these
 *        invalid ids later.
 * @param word_starts An array of length `num_code_points`. The first total word elements contains
 *        the index of the first character for each word.
 * @param word_ends An array of length num_code_points. The first total_words elements contains the
 *        past the end index for each word. This array is kept aligned with the initial
 *        token_ids array containing the word start code points.
 *        `word_ends[word] - filtered_start_indices[word] = word_length`
 * @param tokens_per_word An array of size num_code_points that will contain the number of tokens in
 *        each word in a sentence. This array can be exclusive summed and the result used in
 *        conjunction with the sentence lengths array to find the tokens in each sentence. This is
 *        possible since the number of tokens in each word will be placed at the index corresponding
 *        to the start character of a word. If we assume prefix_summed is the prefix sum of the
 *        tokens_per_word array, then `prefix_summed[sentence_lengths[sentence] - 1]` is the number
 *        of tokens found before the start of sentence.
 * @param unk_token_id The token id to be place for unknown tokens
 * @param max_word_length The maximum length of a word. Any word longer than this length is
 *        replaced by the unknown token.
 * @param total_words The total number of white space separated words
 * @param outer_hash_a_param The a parameter for the outer hash
 * @param outer_hash_b_param: The b parameter for the outer hash
 * @param num_outer_bins: The number of bins for the outer hash
 */
__global__ void kernel_word_piece_tokenizer(uint32_t* code_points,
                                            uint64_t* hash_table,
                                            uint64_t* bin_coefficients,
                                            uint16_t* bin_offsets,
                                            uint32_t* token_ids,
                                            uint32_t* word_starts,
                                            uint32_t* word_ends,
                                            uint8_t* tokens_per_word,
                                            uint16_t unk_token_id,
                                            uint32_t max_word_length,
                                            uint32_t total_words,
                                            uint32_t outer_hash_a_param,
                                            uint32_t outer_hash_b_param,
                                            uint16_t num_outer_bins)
{
  const uint32_t word_to_tokenize = blockDim.x * blockIdx.x + threadIdx.x;

  if (word_to_tokenize >= total_words) return;
  // Each thread gets the start code_point offset for each word and resets the token_id memory to
  // the default value. In a post processing step, all of these values will be removed.
  const uint32_t token_start = word_starts[word_to_tokenize];
  const uint32_t token_end   = word_ends[word_to_tokenize];

  // The sdbm hash of "##"
  constexpr uint32_t hashtag_hash = 2296000;

  uint32_t end = token_end, start = token_start;
  const uint32_t word_length    = token_end - token_start;
  uint16_t num_values_tokenized = 0;

  if (word_length > max_word_length) {
    start                        = token_end;
    num_values_tokenized         = 1;
    token_ids[token_start]       = unk_token_id;
    tokens_per_word[token_start] = num_values_tokenized;
  }

  while (start < token_end) {
    end                   = token_end;
    int token_id          = -1;
    const uint32_t length = token_end - start;
    uint64_t substr_hash =
      sdbm_hash(code_points + start, length, start == token_start ? 0 : hashtag_hash);

    while (start < end) {
      token_id = retrieve(substr_hash,
                          outer_hash_a_param,
                          outer_hash_b_param,
                          num_outer_bins,
                          hash_table,
                          bin_coefficients,
                          bin_offsets);
      if (token_id != -1) { break; }
      --end;
      // Pop off the last value from the substr hash
      substr_hash = prev_sdbm_hash(substr_hash, code_points[end]);
    }

    if (token_id == -1) {
      end      = token_end;
      token_id = unk_token_id;

      // We need to clean up the global array. This case is very uncommon. Only 0.016% of words
      // cannot be resolved to a token from the squad dev set.
      for (uint32_t i = 1; i < num_values_tokenized; ++i) {
        token_ids[token_start + i] = std::numeric_limits<uint32_t>::max();
      }

      num_values_tokenized = 0;
    }

    token_ids[token_start + num_values_tokenized] = token_id;
    ++num_values_tokenized;
    start = end;
  }

  tokens_per_word[token_start] = num_values_tokenized;
}

}  // namespace

full_tokenizer::full_tokenizer(std::string const& vocab_file,
                               uint32_t max_num_sentences,
                               uint32_t max_num_chars,
                               uint32_t max_rows_final_tensor,
                               uint32_t max_sequence_length,
                               uint32_t stride,
                               bool do_truncate,
                               bool do_lower_case,
                               cudaStream_t stream,
                               uint32_t max_word_length)
  : max_sequence_length{max_sequence_length},
    max_word_length{max_word_length},
    stride(stride),
    do_truncate(do_truncate),
    normalizer(max_num_sentences, max_num_chars, cp_data, aux_data, do_lower_case, stream)
// tokenizer(vocab_file, max_num_chars, max_word_length, stream)
// tensor_tokenIDS(max_rows_final_tensor * max_sequence_length),
// attention_mask(max_rows_final_tensor * max_sequence_length),
// metadata(max_rows_final_tensor * 3),
// device_row2log(max_rows_final_tensor),
// device_row2row_within_log(max_rows_final_tensor)
{
  detail::transfer_hash_info_to_device(vocab_file,
                                       device_hash_table,
                                       device_bin_coefficients,
                                       device_bin_offsets,
                                       unk_token_id,
                                       first_tok_id,
                                       sep_tok_id,
                                       outer_hash_a_param,
                                       outer_hash_b_param,
                                       num_outer_bins);

  
  const size_t max_new_char_total = MAX_NEW_CHARS * max_num_chars;
  device_token_ids.resize(max_new_char_total);
  const size_t device_word_indices_count = 2 * max_new_char_total;
  device_word_indices.resize(device_word_indices_count);

  const size_t four_byte_cp_chunks = 1 + (max_new_char_total - 1) / sizeof(uint32_t);
  const size_t rounded_num_cps     = sizeof(uint32_t) * four_byte_cp_chunks;
  device_tokens_per_word.resize(rounded_num_cps);

  // Determine temporary device storage requirements for cub
  static NotEqual select_op(std::numeric_limits<uint32_t>::max());
  size_t temp_storage_bytes = 0, temp_storage_bytes_2 = 0;
  cub::DeviceSelect::If(nullptr,
                        temp_storage_bytes,
                        device_word_indices.data().get(),
                        device_word_indices.data().get(),
                        device_num_selected.data().get(),
                        2 * max_new_char_total,
                        select_op);
  cub::DeviceScan::InclusiveSum(nullptr,
                                temp_storage_bytes_2,
                                device_tokens_per_word.data().get(),
                                device_word_indices.data().get(),
                                max_new_char_total);
  max_cub_storage_bytes = std::max(temp_storage_bytes, temp_storage_bytes_2);
  cub_temp_storage.resize(max_cub_storage_bytes);
  device_num_selected.resize(1);
}

std::pair<uint32_t*, uint32_t*> full_tokenizer::tokenize(const char* d_strings,
                                                         const uint32_t* d_offsets,
                                                         uint32_t num_strings,
                                                         cudaStream_t stream)
{
  auto cps_and_offsets = normalizer.normalize(d_strings, d_offsets, num_strings, stream);
  tokenize(cps_and_offsets.first, cps_and_offsets.second, stream);
  // return cps_and_offsets;
  return std::make_pair(cps_and_offsets.first.gpu_ptr, cps_and_offsets.second.gpu_ptr);
#if 0  
  uint32_t* device_token_ids = cps_and_offsets.first.gpu_ptr;
  uint32_t* device_offsets   = cps_and_offsets.second.gpu_ptr;

  // copy log offsets to host
  std::vector<uint32_t> host_offsets;
  host_offsets.resize(num_strings + 1);
  CUDA_TRY(cudaMemcpyAsync(host_offsets.data(),
                           device_offsets,
                           sizeof(uint32_t) * (num_strings + 1),
                           cudaMemcpyDeviceToHost,
                           stream));

  // compute number of rows required for final tensor
  nrows_tensor_tokenIDS = 0;
  std::vector<uint32_t> nrows_per_log;
  nrows_per_log.resize(num_strings);
  for (uint32_t i = 0; i < num_strings; i++) {
    uint32_t ntokens = host_offsets[i + 1] - host_offsets[i];
    if (do_truncate || ntokens <= max_sequence_length)
      nrows_per_log[i] = 1;
    else {
      ntokens -= max_sequence_length;
      nrows_per_log[i] = 1 + (ntokens / stride);
      if (ntokens % stride) nrows_per_log[i]++;
    }
    nrows_tensor_tokenIDS += nrows_per_log[i];
  }
  // compute global_row to log, and global_row to within_log_row correspondence
  std::vector<uint32_t> host_row2log;
  std::vector<uint32_t> host_row2row_within_log;
  host_row2log.resize(nrows_tensor_tokenIDS);
  host_row2row_within_log.resize(nrows_tensor_tokenIDS);
  int row_id = 0;
  for (uint32_t i = 0; i < num_strings; i++) {
    for (uint32_t j = 0; j < nrows_per_log[i]; j++) {
      host_row2log[row_id]            = i;
      host_row2row_within_log[row_id] = j;
      row_id++;
    }
  }

  // copy info to GPU
  device_row2log            = host_row2log;
  device_row2row_within_log = host_row2row_within_log;

  // compute final-tensor, mask, and metadata
  compute_tensor_metadata_kernel<<<nrows_tensor_tokenIDS, max_sequence_length, 0, stream>>>(
    device_token_ids,
    device_offsets,
    thrust::raw_pointer_cast(device_row2log.data()),
    thrust::raw_pointer_cast(device_row2row_within_log.data()),
    max_sequence_length,
    stride,
    do_truncate,
    thrust::raw_pointer_cast(tensor_tokenIDS.data()),
    thrust::raw_pointer_cast(attention_mask.data()),
    thrust::raw_pointer_cast(metadata.data()));
#endif
}

void full_tokenizer::tokenize(ptr_length_pair& cp_and_length,
                              ptr_length_pair& offsets_and_length,
                              cudaStream_t stream)
{
  uint32_t* device_code_points = cp_and_length.gpu_ptr;
  size_t num_code_points       = cp_and_length.length;

  uint32_t* device_sentence_offsets = offsets_and_length.gpu_ptr;
  uint32_t num_sentences            = offsets_and_length.length - 1;

  // Create a selection op for all device selects
  static NotEqual select_op(std::numeric_limits<uint32_t>::max());

  // make device_start_word_indices and device_end_word_indices contiguous
  uint32_t* device_start_word_indices = thrust::raw_pointer_cast(device_word_indices.data());
  uint32_t* device_end_word_indices   = device_start_word_indices + num_code_points;

  uint32_t total_threads               = num_code_points;
  constexpr uint32_t threads_per_block = 64;
  uint32_t num_blocks = (total_threads + threads_per_block - 1) / threads_per_block;
  detail::init_data_and_mark_word_start_and_ends<<<num_blocks, threads_per_block, 0, stream>>>(
    device_code_points,
    device_start_word_indices,
    device_end_word_indices,
    num_code_points,
    thrust::raw_pointer_cast(device_token_ids.data()),
    thrust::raw_pointer_cast(device_tokens_per_word.data()));
  CHECK_CUDA(stream);

  uint32_t word_split_blocks = (num_sentences + threads_per_block - 1) / threads_per_block;
  detail::mark_sentence_start_and_ends<<<word_split_blocks, threads_per_block, 0, stream>>>(
    device_code_points,
    device_sentence_offsets,
    device_start_word_indices,
    device_end_word_indices,
    num_sentences);
  CHECK_CUDA(stream);

  // Now start_word_indices has the word starts scattered throughout the array. We need to select
  // all values not equal to the max uint32_t and place them at the start of the array. We leverage
  // the fact that the start_word_indices and the end_word indices are contiguous to only launch one
  // device select kernel.
  cub::DeviceSelect::If(thrust::raw_pointer_cast(cub_temp_storage.data()),
                        max_cub_storage_bytes,
                        device_start_word_indices,
                        device_start_word_indices,
                        thrust::raw_pointer_cast(device_num_selected.data()),
                        2 * num_code_points,
                        select_op);
  CHECK_CUDA(stream);

  // Grab the number of words which is the number of threads needed for the main word piece
  // tokenizer kernel. The number of tokens selected out will be double the number of words since we
  // select from both the start and end index arrays.
  uint32_t num_words = 0;
  device_num_selected.resize(1);
  CUDA_TRY(cudaMemcpy(&num_words,
                      thrust::raw_pointer_cast(device_num_selected.data()),
                      sizeof(num_words),
                      cudaMemcpyDeviceToHost));

  num_words /= 2;

  // We need to change the end_word_indices pointer after the selection is complete
  device_end_word_indices = device_start_word_indices + num_words;

  const uint32_t wp_threads_per_block = 64;
  const uint32_t num_wp_blocks = (num_words + wp_threads_per_block - 1) / wp_threads_per_block;
  detail::kernel_word_piece_tokenizer<<<num_wp_blocks, wp_threads_per_block, 0, stream>>>(
    device_code_points,
    thrust::raw_pointer_cast(device_hash_table.data()),
    thrust::raw_pointer_cast(device_bin_coefficients.data()),
    thrust::raw_pointer_cast(device_bin_offsets.data()),
    thrust::raw_pointer_cast(device_token_ids.data()),
    device_start_word_indices,
    device_end_word_indices,
    thrust::raw_pointer_cast(device_tokens_per_word.data()),
    unk_token_id,
    max_word_length,
    num_words,
    outer_hash_a_param,
    outer_hash_b_param,
    num_outer_bins);
  CHECK_CUDA(stream);

  // Repurpose the input array for the token ids. In the worst case, each code point ends up being a
  // token so this will always have enough memory to store the contiguous tokens.
  uint32_t* contiguous_token_ids = device_code_points;
  cub::DeviceSelect::If(thrust::raw_pointer_cast(cub_temp_storage.data()),
                        max_cub_storage_bytes,
                        thrust::raw_pointer_cast(device_token_ids.data()),
                        contiguous_token_ids,
                        thrust::raw_pointer_cast(device_num_selected.data()),
                        num_code_points,
                        select_op);
  CHECK_CUDA(stream);

  // Repurpose start word indices since it is the same size and type as the required output.
  uint32_t* token_id_counts = device_start_word_indices;
  device_start_word_indices = nullptr;
  cub::DeviceScan::InclusiveSum(thrust::raw_pointer_cast(cub_temp_storage.data()),
                                max_cub_storage_bytes,
                                thrust::raw_pointer_cast(device_tokens_per_word.data()),
                                token_id_counts,
                                num_code_points);
  CHECK_CUDA(stream);

  constexpr uint16_t sen_update_num_threads = 64;
  size_t SEN_KERNEL_BLOCKS = (num_sentences + sen_update_num_threads - 1) / sen_update_num_threads;
  update_sentence_lengths<<<SEN_KERNEL_BLOCKS, sen_update_num_threads, 0, stream>>>(
    device_sentence_offsets, token_id_counts, num_sentences);
  CHECK_CUDA(stream);

  // Grab total number of token ids from the device
  uint32_t total_token_ids = 0;
  CUDA_TRY(cudaMemcpyAsync(&total_token_ids,
                           token_id_counts + num_code_points - 1,
                           sizeof(total_token_ids),
                           cudaMemcpyDeviceToHost,
                           stream));

  cp_and_length.length = total_token_ids;
}

// uint32_t full_tokenizer::get_nrows_tensor_tokenIDS() { return nrows_tensor_tokenIDS; }
//
// uint32_t* full_tokenizer::get_tensor_tokenIDS()
//{
//  return thrust::raw_pointer_cast(tensor_tokenIDS.data());
//}
//
// uint32_t* full_tokenizer::get_attention_mask()
//{
//  return thrust::raw_pointer_cast(attention_mask.data());
//}
//
// uint32_t* full_tokenizer::get_tensor_metadata()
//{
//  return thrust::raw_pointer_cast(metadata.data());
//}

}  // namespace detail
}  // namespace nvtext
