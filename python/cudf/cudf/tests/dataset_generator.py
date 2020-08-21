# Copyright (c) 2020, NVIDIA CORPORATION.

# This module is for generating "synthetic" datasets. It was originally
# designed for testing filtered reading. Generally, it should be useful
# if you want to generate data where certain phenomena (e.g., cardinality)
# are exaggurated.

import pandas as pd
import numpy as np

import pyarrow as pa
import pyarrow.parquet as pq
from mimesis import Generic


class ColumnParameters:
    """Parameters for generating column of data

    Attributes
    ---
    cardinality : int or None
        Size of a random set of values that generated data is sampled from.
        The values in the random set are derived from the given generator.
        If cardinality is None, the Iterable returned by the given generator
        is invoked for each value to be generated.
    null_frequency : 0.1
        Probability of a generated value being null
    generator : Callable
        Function for generating random data. It is passed a Mimesis Generic
        provider and returns an Iterable that generates data.
    is_sorted : bool
        Sort this column. Columns are sorted in same order as ColumnParameters
        instances stored in column_params of Parameters.
    """

    def __init__(
        self,
        cardinality=100,
        null_frequency=0.1,
        generator=lambda g: (g.address.country for _ in range(100)),
        is_sorted=True,
    ):
        self.cardinality = cardinality
        self.null_frequency = null_frequency
        self.generator = generator
        self.is_sorted = is_sorted


class Parameters:
    """Parameters for random dataset generation

    Attributes
    ---
    num_rows : int
        Number of rows to generate
    column_params : List[ColumnParams]
        ColumnParams for each column
    seed : int or None, default None
        Seed for random data generation
    """

    def __init__(
        self, num_rows=2048, column_parameters=[], seed=None,
    ):
        self.num_rows = num_rows
        self.column_parameters = column_parameters
        self.seed = seed


def _write(tbl, path, format):
    if format["name"] == "parquet":
        if isinstance(tbl, pa.Table):
            pq.write_table(tbl, path, row_group_size=format["row_group_size"])
        elif isinstance(tbl, pd.DataFrame):
            tbl.to_parquet(path, row_group_size=format["row_group_size"])


def generate(
    path, parameters, format={"name": "parquet", "row_group_size": 64}
):
    """
    Generate dataset using given parameters and write to given format

    Parameters
    ----------
    path : str or file-like object
        Path to write to
    parameters : Parameters
        Parameters specifying how to randomly generate data
    format : Dict
        Format to write
    """

    # Initialize seeds
    g = Generic("en", seed=parameters.seed)
    if parameters.seed is not None:
        np.random.seed(parameters.seed)

    # Generate data for each column in Arrow Table
    schema = pa.schema(
        [
            pa.field(
                name=str(i),
                type=pa.from_numpy_dtype(
                    type(next(iter(column_params.generator(g))))
                ),
                nullable=column_params.null_frequency > 0,
            )
            for i, column_params in enumerate(parameters.column_parameters)
        ]
    )
    column_data = []
    columns_to_sort = [
        str(i)
        for i, column_params in enumerate(parameters.column_parameters)
        if column_params.is_sorted
    ]
    for i, column_params in enumerate(parameters.column_parameters):
        generator = column_params.generator(g)
        if column_params.cardinality is not None:
            # Construct set of values to sample from where set size = cardinality
            vals = pa.array(
                generator, size=column_params.cardinality, safe=False,
            )

            # Generate data for current column
            choices = np.random.randint(
                0, len(vals) - 1, size=parameters.num_rows
            )
            column_data.append(
                pa.array(
                    [
                        vals[choices[i]].as_py()
                        for i in range(parameters.num_rows)
                    ],
                    mask=np.random.choice(
                        [True, False],
                        size=parameters.num_rows,
                        p=[
                            column_params.null_frequency,
                            1 - column_params.null_frequency,
                        ],
                    )
                    if column_params.null_frequency > 0.0
                    else None,
                    size=parameters.num_rows,
                    safe=False,
                )
            )
        else:
            # Generate data for current column
            column_data.append(
                pa.array(
                    generator,
                    mask=np.random.choice(
                        [True, False],
                        size=parameters.num_rows,
                        p=[
                            column_params.null_frequency,
                            1 - column_params.null_frequency,
                        ],
                    ),
                    size=parameters.num_rows,
                    safe=False,
                )
            )

    # Convert to Pandas DataFrame and sort columns appropriately
    tbl = pa.Table.from_arrays(column_data, schema=schema,)
    if columns_to_sort:
        tbl = tbl.to_pandas()
        tbl = tbl.sort_values(columns_to_sort)

    # Write
    _write(tbl, path, format)
