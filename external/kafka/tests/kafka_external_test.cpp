/*
 * Copyright (c) 2019, NVIDIA CORPORATION.
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
#include <gmock/gmock.h>
#include <gtest/gtest.h>

#include <sys/stat.h>
#include <string>
#include <vector>
#include <map>

#include <kafka_datasource.hpp>

TEST(ExternalDatasource, Basic)
{
    std::map<std::string, std::string> datasource_confs;

    //Topic
    datasource_confs.insert({"ex_ds.kafka.topic", "libcudf-test"});

    //General Conf
    datasource_confs.insert({"bootstrap.servers", "localhost:9092"});
    datasource_confs.insert({"group.id", "jeremy_test"});
    datasource_confs.insert({"auto.offset.reset", "beginning"});

    cudf::io::external::kafka_datasource *ex_datasource(datasource_confs);
    std::string json_str = ex_datasource->consume_range(datasource_confs, 0, 3, 10000);
}
