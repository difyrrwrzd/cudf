/*
 * Copyright (c) 2023, NVIDIA CORPORATION.
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
package ai.rapids.cudf;

/**
 * A device memory resource that will limit the maximum amount allocated.
 */
public class RmmLimitingResourceAdaptor<C extends RmmDeviceMemoryResource>
    extends RmmWrappingDeviceMemoryResource<C> {
  private final long limit;
  private final long alignment;
  private long handle = 0;

  /**
   * Create a new limiting resource adaptor.
   * @param wrapped the memory resource to limit. This should not be reused.
   * @param limit the allocation limit in bytes
   * @param alignment the alignment
   */
  public RmmLimitingResourceAdaptor(C wrapped, long limit, long alignment) {
    super(wrapped);
    this.limit = limit;
    this.alignment = alignment;
    handle = Rmm.newLimitingResourceAdaptor(wrapped.getHandle(), limit, alignment);
  }

  @Override
  public long getHandle() {
    return handle;
  }

  @Override
  public void close() {
    if (handle != 0) {
      Rmm.releaseLimitingResourceAdaptor(handle);
      handle = 0;
    }
    super.close();
  }

  @Override
  public String toString() {
    return Long.toHexString(getHandle()) + "/LIMIT(" + wrapped +
        ", " + limit + ", " + alignment + ")";
  }
}
