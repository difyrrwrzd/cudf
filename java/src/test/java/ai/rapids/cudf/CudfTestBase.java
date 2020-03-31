/*
 *
 *  Copyright (c) 2019, NVIDIA CORPORATION.
 *
 *  Licensed under the Apache License, Version 2.0 (the "License");
 *  you may not use this file except in compliance with the License.
 *  You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
 *
 */

package ai.rapids.cudf;

import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.HashMap;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.fail;
import static org.junit.jupiter.api.Assumptions.assumeTrue;

class CudfTestBase {
  static final long RMM_POOL_SIZE_DEFAULT = 512 * 1024 * 1024;

  final int rmmAllocationMode;
  final long rmmPoolSize;

  CudfTestBase() {
    this(RmmAllocationMode.POOL, RMM_POOL_SIZE_DEFAULT);
  }

  CudfTestBase(int allocationMode, long poolSize) {
    this.rmmAllocationMode = allocationMode;
    this.rmmPoolSize = poolSize;
  }

  static class Listener extends MemoryListener {
    private static final Logger LOG = LoggerFactory.getLogger(Listener.class);
    HashMap<Long, StackTraceElement[]> outstanding = new HashMap<>();

    @Override
    public void prediction(long amount, String note) {
      LOG.debug("PREDICT {} {}", amount, note);
    }

    @Override
    public void allocation(long amount, long id) {
      LOG.debug("ALLOC {} {}", amount, id);
      outstanding.put(id, Thread.currentThread().getStackTrace());
    }

    @Override
    public void endPrediction(String note) {
      LOG.debug("END PREDICT {}", note);
    }

    @Override
    public void deallocation(long amount, long id) {
      LOG.debug("DEALLOC {} {}", amount, id);
      StackTraceElement[] was = outstanding.remove(id);
      if (was == null) {
        LOG.error("DEALLOC FOR SOMETHING THAT WAS NOT ALLOCATED", new Exception("__STACK_TRACE"));
      }
    }

    public void checkOutstanding() {
      if (outstanding.size() > 0) {
        LOG.error("{} ALLOCATIONS NOT RELEASED", outstanding.size());
        for (Map.Entry<Long, StackTraceElement[]> entry: outstanding.entrySet()) {
          LOG.error("{}:", entry.getKey());
          for (StackTraceElement elem: entry.getValue()) {
            LOG.error("\t{}", elem);
          }
        }
      }
    }
  }

  static final Listener LISTENER = new Listener();

  @BeforeAll
  static void setupMemoryListener() {
    MemoryListener.registerDeviceListener(LISTENER);
  }

  @BeforeEach
  void beforeEach() {
    assumeTrue(Cuda.isEnvCompatibleForTesting());
    if (!Rmm.isInitialized()) {
      Rmm.initialize(rmmAllocationMode, false, rmmPoolSize);
    }
  }

  @AfterAll
  static void afterAll() {
    if (Rmm.isInitialized()) {
      Rmm.shutdown();
    }
    LISTENER.checkOutstanding();
  }

  private static boolean doublesAreEqualWithinPercentage(double expected, double actual, double percentage) {
    // doubleToLongBits will take care of returning true when both operands have same long value
    // including +ve infinity, -ve infinity or NaNs
    if (Double.doubleToLongBits(expected) != Double.doubleToLongBits(actual)) {
      if (expected != 0) {
        return Math.abs((expected - actual) / expected) <= percentage;
      } else {
        return Math.abs(expected - actual) <= percentage;
      }
    } else {
      return true;
    }
  }

  /**
   * Fails if the absolute difference between expected and actual values as a percentage of the expected
   * value is greater than the threshold
   * i.e. Math.abs((expected - actual) / expected) > percentage, if expected != 0
   * else Math.abs(expected - actual) > percentage
   */
  static void assertEqualsWithinPercentage(double expected, double actual, double percentage) {
     assertEqualsWithinPercentage(expected, actual, percentage, "");
  }

  /**
   * Fails if the absolute difference between expected and actual values as a percentage of the expected
   * value is greater than the threshold
   * i.e. Math.abs((expected - actual) / expected) > percentage, if expected != 0
   * else Math.abs(expected - actual) > percentage
   */
  static void assertEqualsWithinPercentage(double expected, double actual, double percentage, String message) {
    if (!doublesAreEqualWithinPercentage(expected, actual, percentage)) {
      String msg = message + " Math.abs(expected - actual)";
      String eq = (expected != 0 ?
                      " / Math.abs(expected) = " + Math.abs((expected - actual) / expected)
                    : " = " + Math.abs(expected - actual));
      fail(msg + eq + " is not <= " + percentage);
    }
  }
}
