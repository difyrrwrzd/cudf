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

#include <benchmark/benchmark.h>

#include <benchmarks/common/generate_benchmark_input.hpp>
#include <benchmarks/fixture/benchmark_fixture.hpp>
#include <benchmarks/synchronization/synchronization.hpp>

#include <cudf/io/functions.hpp>

// to enable, run cmake with -DBUILD_BENCHMARKS=ON

constexpr int64_t data_size        = 512 << 20;
constexpr cudf::size_type num_cols = 64;

namespace cudf_io = cudf::io;

class OrcRead : public cudf::benchmark {
};

void ORC_read(benchmark::State& state)
{
  auto const data_types             = get_type_or_group(state.range(0));
  cudf::size_type const cardinality = state.range(1);
  cudf::size_type const run_length  = state.range(2);
  cudf_io::compression_type const compression =
    state.range(3) ? cudf_io::compression_type::SNAPPY : cudf_io::compression_type::NONE;

  data_profile table_data_profile;
  table_data_profile.set_cardinality(cardinality);
  table_data_profile.set_avg_run_length(run_length);
  auto const tbl =
    create_random_table(data_types, num_cols, table_size_bytes{data_size}, table_data_profile);
  auto const view = tbl->view();

  std::vector<char> out_buffer;
  out_buffer.reserve(data_size);
  cudf_io::write_orc_args args{cudf_io::sink_info(&out_buffer), view, nullptr, compression};
  cudf_io::write_orc(args);

  cudf_io::read_orc_args read_args{cudf_io::source_info(out_buffer.data(), out_buffer.size())};

  for (auto _ : state) {
    cuda_event_timer raii(state, true);  // flush_l2_cache = true, stream = 0
    cudf_io::read_orc(read_args);
  }

  state.SetBytesProcessed(data_size * state.iterations());
}

// TODO: replace with ArgsProduct once available
#define ORC_RD_BENCHMARK_DEFINE(name, type_or_group)  \
  BENCHMARK_DEFINE_F(OrcRead, name)                   \
  (::benchmark::State & state) { ORC_read(state); }   \
  BENCHMARK_REGISTER_F(OrcRead, name)                 \
    ->Args({int32_t(type_or_group), 0, 1, false})     \
    ->Args({int32_t(type_or_group), 0, 1, true})      \
    ->Args({int32_t(type_or_group), 0, 32, false})    \
    ->Args({int32_t(type_or_group), 0, 32, true})     \
    ->Args({int32_t(type_or_group), 1000, 1, false})  \
    ->Args({int32_t(type_or_group), 1000, 1, true})   \
    ->Args({int32_t(type_or_group), 1000, 32, false}) \
    ->Args({int32_t(type_or_group), 1000, 32, true})  \
    ->Unit(benchmark::kMillisecond)                   \
    ->UseManualTime();

// ORC does not support unsigned int types
ORC_RD_BENCHMARK_DEFINE(integral_signed, type_group_id::INTEGRAL_SIGNED);
ORC_RD_BENCHMARK_DEFINE(floats, type_group_id::FLOATING_POINT);
ORC_RD_BENCHMARK_DEFINE(timestamps, type_group_id::TIMESTAMP);
ORC_RD_BENCHMARK_DEFINE(string, cudf::type_id::STRING);
