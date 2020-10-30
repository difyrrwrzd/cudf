/*
 *  Copyright (c) 2020, NVIDIA CORPORATION.
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

import ai.rapids.cudf.HostColumnVector.Builder;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.Random;

import static org.junit.jupiter.api.Assertions.*;

public class DecimalColumnVectorTest extends CudfTestBase {
  private final Random rdSeed = new Random(1234);

  private final BigDecimal[] decimal32Zoo = new BigDecimal[]{
    BigDecimal.valueOf(rdSeed.nextInt() / 10, 4),
    BigDecimal.valueOf(rdSeed.nextInt() / 10, 4),
    BigDecimal.valueOf(rdSeed.nextInt() / 10, 4),
    BigDecimal.valueOf(rdSeed.nextInt() / 10, 4),
  };

  private final BigDecimal[] decimal64Zoo = new BigDecimal[]{
    BigDecimal.valueOf(rdSeed.nextLong() / 10, 10),
    BigDecimal.valueOf(rdSeed.nextLong() / 10, 10),
    null,
    BigDecimal.valueOf(rdSeed.nextLong() / 10, 10),
  };

  private final BigDecimal[] boundaryDecimal32 = new BigDecimal[]{
      new BigDecimal("999999999"), new BigDecimal("-999999999")};

  private final BigDecimal[] boundaryDecimal64 = new BigDecimal[]{
      new BigDecimal("999999999999999999"), new BigDecimal("-999999999999999999")};

  private final BigDecimal[] overflowDecimal32 = new BigDecimal[]{
      BigDecimal.valueOf(Integer.MAX_VALUE), BigDecimal.valueOf(Integer.MIN_VALUE)};

  private final BigDecimal[] overflowDecimal64 = new BigDecimal[]{
      BigDecimal.valueOf(Long.MAX_VALUE), BigDecimal.valueOf(Long.MIN_VALUE)};

  @Test
  public void testCreateColumnVectorBuilder() {
    try (ColumnVector decColumnVector = ColumnVector.build(DType.create(DType.DTypeEnum.DECIMAL32, -5), 3,
        (b) -> b.append(BigDecimal.valueOf(123456789, 5)))) {
      assertFalse(decColumnVector.hasNulls());
    }
    try (ColumnVector decColumnVector = ColumnVector.build(DType.create(DType.DTypeEnum.DECIMAL64, -10), 3,
        (b) -> b.append(BigDecimal.valueOf(1023040506070809L, 10)))) {
      assertFalse(decColumnVector.hasNulls());
    }
  }

  @Test
  public void testUpperIndexOutOfBoundsException() {
    try (HostColumnVector decColumnVector = HostColumnVector.fromDecimals(decimal32Zoo)) {
      assertThrows(AssertionError.class, () -> decColumnVector.getBigDecimal(4));
      assertFalse(decColumnVector.hasNulls());
    }
  }

  @Test
  public void testLowerIndexOutOfBoundsException() {
    try (HostColumnVector doubleColumnVector = HostColumnVector.fromDecimals(decimal32Zoo)) {
      assertFalse(doubleColumnVector.hasNulls());
      assertThrows(AssertionError.class, () -> doubleColumnVector.getBigDecimal(-1));
    }
  }

  @Test
  public void testAddingNullValues() {
    try (HostColumnVector cv = HostColumnVector.fromDecimals(decimal64Zoo)) {
      int nullCount = 0;
      for (int i = 0; i < decimal64Zoo.length; ++i) {
        assertEquals(decimal64Zoo[i] == null, cv.isNull(i));
      }
      assertEquals(nullCount > 0, cv.hasNulls());
      assertEquals(nullCount, cv.getNullCount());
    }
  }

  @Test
  public void testOverrunningTheBuffer() {
    try (Builder builder = HostColumnVector.builder(DType.create(DType.DTypeEnum.DECIMAL32, 4), 3)) {
      assertThrows(AssertionError.class,
          () -> builder.append(decimal32Zoo[0]).appendNull().appendBoxed(decimal32Zoo[1], decimal32Zoo[2]).build());
    }
  }

  @Test
  public void testDecimalValidation() {
    // inconsistent scales
    assertThrows(AssertionError.class,
        () -> HostColumnVector.fromDecimals(BigDecimal.valueOf(12.3), BigDecimal.valueOf(1.23)));
    // precision overflow
    assertThrows(AssertionError.class, () -> HostColumnVector.fromDecimals(overflowDecimal64));
  }

  @Test
  public void testDecimalSpecifics() {
    DecimalColumnVectorTest.testDecimalInternal(decimal32Zoo);
    DecimalColumnVectorTest.testDecimalInternal(decimal64Zoo);
    DecimalColumnVectorTest.testDecimalInternal(boundaryDecimal32);
    DecimalColumnVectorTest.testDecimalInternal(boundaryDecimal64);
    // Safe max precision of Decimal32 is 9, so integers have 10 digits will be backed by DECIMAL64.
    try (ColumnVector cv = ColumnVector.fromDecimals(overflowDecimal32)) {
      assertEquals(DType.create(DType.DTypeEnum.DECIMAL64, 0), cv.getDataType());
    }
  }

  private static void testDecimalInternal(BigDecimal[] decimalZoo) {
    try (ColumnVector cv = ColumnVector.fromDecimals(decimalZoo)) {
      try (HostColumnVector hcv = cv.copyToHost()) {
        assertEquals(decimalZoo.length, hcv.rows);
        int index = 0;
        for (BigDecimal dec : decimalZoo) {
          if (dec == null) {
            assertTrue(hcv.isNull(index));
          } else {
            assertFalse(hcv.isNull(index));
            assertEquals(dec, hcv.getBigDecimal(index));
          }
          index++;
        }
      }
    }
  }

  @Test
  public void testAppendVector() {
    for (DType decType : new DType[]{
        DType.create(DType.DTypeEnum.DECIMAL32, -6),
        DType.create(DType.DTypeEnum.DECIMAL64, -10)}) {
      for (int dstSize = 1; dstSize <= 100; dstSize++) {
        for (int dstPrefilledSize = 0; dstPrefilledSize < dstSize; dstPrefilledSize++) {
          final int srcSize = dstSize - dstPrefilledSize;
          for (int sizeOfDataNotToAdd = 0; sizeOfDataNotToAdd <= dstPrefilledSize; sizeOfDataNotToAdd++) {
            try (Builder dst = HostColumnVector.builder(decType, dstSize);
                 HostColumnVector src = HostColumnVector.build(decType, srcSize, (b) -> {
                   for (int i = 0; i < srcSize; i++) {
                     if (rdSeed.nextBoolean()) {
                       b.appendNull();
                     } else {
                       b.append(BigDecimal.valueOf(rdSeed.nextInt(), -decType.getScale()));
                     }
                   }
                 });
                 Builder gtBuilder = HostColumnVector.builder(decType, dstPrefilledSize)) {
              assertEquals(dstSize, srcSize + dstPrefilledSize);
              //add the first half of the prefilled list
              for (int i = 0; i < dstPrefilledSize - sizeOfDataNotToAdd; i++) {
                if (rdSeed.nextBoolean()) {
                  dst.appendNull();
                  gtBuilder.appendNull();
                } else {
                  BigDecimal a = BigDecimal.valueOf(rdSeed.nextInt(), -decType.getScale());
                  dst.append(a);
                  gtBuilder.append(a);
                }
              }
              // append the src vector
              dst.append(src);
              try (HostColumnVector dstVector = dst.build();
                   HostColumnVector gt = gtBuilder.build()) {
                for (int i = 0; i < dstPrefilledSize - sizeOfDataNotToAdd; i++) {
                  assertEquals(gt.isNull(i), dstVector.isNull(i));
                  if (!gt.isNull(i)) {
                    assertEquals(gt.getBigDecimal(i), dstVector.getBigDecimal(i));
                  }
                }
                for (int i = dstPrefilledSize - sizeOfDataNotToAdd, j = 0; i < dstSize - sizeOfDataNotToAdd && j < srcSize; i++, j++) {
                  assertEquals(src.isNull(j), dstVector.isNull(i));
                  if (!src.isNull(j)) {
                    assertEquals(src.getBigDecimal(j), dstVector.getBigDecimal(i));
                  }
                }
                if (dstVector.hasValidityVector()) {
                  long maxIndex =
                      BitVectorHelper.getValidityAllocationSizeInBytes(dstVector.getRowCount()) * 8;
                  for (long i = dstSize - sizeOfDataNotToAdd; i < maxIndex; i++) {
                    assertFalse(dstVector.isNullExtendedRange(i));
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
