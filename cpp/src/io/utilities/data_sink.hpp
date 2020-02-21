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

#pragma once


#include <memory>
#include <vector>
#include <string>

namespace cudf {
namespace io {

/**
 * @brief Interface class for storing the output data from the writers
 **/
class data_sink {
 public:
  /**
   * @brief Create a sink from a file path
   *
   * @param[in] filepath Path to the file to use
   **/
  static std::unique_ptr<data_sink> create(const std::string& filepath);

  /**
   * @brief Create a sink from a std::vector
   *
   * @param[in,out] buffer Pointer to the output vector
   **/
  static std::unique_ptr<data_sink> create(std::vector<char>* buffer);

  /**
   * @brief Create a void sink (one that does no actual io)
   * 
   * A useful code path for benchmarking, to eliminate physical
   * hardware randomness from profiling.
   *   
   **/
  static std::unique_ptr<data_sink> create();

  /**
   * @brief Create a wrapped custom user data sink
   * 
   * @param[in] User-provided data sink (typically custom class)
   *
   * The data sink returned here is not the one passed by the user. It is an internal
   * class that wraps the user pointer.  The principle is to allow the user to declare
   * a custom sink instance and use it across multiple write() calls.
   *   
   **/
  static std::unique_ptr<data_sink> create(std::shared_ptr<cudf::io::data_sink> user_sink);

  /**
   * @brief Base class destructor
   **/
  virtual ~data_sink(){};

  /**
   * @brief Append the buffer content to the sink
   *
   * @param[in] data Pointer to the buffer to be written into the sink object
   * @param[in] size Number of bytes to write
   *
   * @return void
   **/
  virtual void write(void const* data, size_t size) = 0;

  /**
   * @brief Flush the data written into the sink
   * 
   * @return void
   */
  virtual void flush() = 0;
  
  /**
   * @brief Returns the total number of bytes written into this sink
   *
   * @return size_t Total number of bytes written into this sink
   **/
  virtual size_t bytes_written() = 0;
};

}  // namespace io
}  // namespace cudf
