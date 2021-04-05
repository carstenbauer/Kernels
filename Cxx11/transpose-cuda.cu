///
/// Copyright (c) 2013, Intel Corporation
/// Copyright (c) 2015, NVIDIA CORPORATION.
///
/// Redistribution and use in source and binary forms, with or without
/// modification, are permitted provided that the following conditions
/// are met:
///
/// * Redistributions of source code must retain the above copyright
///       notice, this list of conditions and the following disclaimer.
/// * Redistributions in binary form must reproduce the above
///       copyright notice, this list of conditions and the following
///       disclaimer in the documentation and/or other materials provided
///       with the distribution.
/// * Neither the name of Intel Corporation nor the names of its
///       contributors may be used to endorse or promote products
///       derived from this software without specific prior written
///       permission.
///
/// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
/// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
/// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
/// FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
/// COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
/// INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
/// BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
/// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
/// CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
/// LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
/// ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
/// POSSIBILITY OF SUCH DAMAGE.

//////////////////////////////////////////////////////////////////////
///
/// NAME:    transpose
///
/// PURPOSE: This program measures the time for the transpose of a
///          column-major stored matrix into a row-major stored matrix.
///
/// USAGE:   Program input is the matrix order and the number of times to
///          repeat the operation:
///
///          transpose <matrix_size> <# iterations> [tile size]
///
///          An optional parameter specifies the tile size used to divide the
///          individual matrix blocks for improved cache and TLB performance.
///
///          The output consists of diagnostics to make sure the
///          transpose worked and timing statistics.
///
/// HISTORY: Written by  Rob Van der Wijngaart, February 2009.
///          Converted to C++11 by Jeff Hammond, February 2016 and May 2017.
///
//////////////////////////////////////////////////////////////////////

#include "prk_util.h"
#include "prk_cuda.h"

#define TILED 0

#if TILED
// The kernel was derived from https://github.com/parallel-forall/code-samples/blob/master/series/cuda-cpp/transpose/transpose.cu,
// which is the reason for the additional copyright noted above.

const int tile_dim = 32;
const int block_rows = 8;

__global__ void transpose(int order, double * A, double * B)
{
    auto x = blockIdx.x * tile_dim + threadIdx.x;
    auto y = blockIdx.y * tile_dim + threadIdx.y;
    auto width = gridDim.x * tile_dim;

    for (int j = 0; j < tile_dim; j+= block_rows) {
        B[x*width + (y+j)] += A[(y+j)*width + x];
        A[(y+j)*width + x] += (double)1;
    }
}
#else
__global__ void transpose(unsigned order, double * A, double * B)
{
    auto i = blockIdx.x * blockDim.x + threadIdx.x;
    auto j = blockIdx.y * blockDim.y + threadIdx.y;

    if ((i<order) && (j<order)) {
        B[i*order+j] += A[j*order+i];
        A[j*order+i] += (double)1;
    }
}
#endif

int main(int argc, char * argv[])
{
  std::cout << "Parallel Research Kernels version " << PRKVERSION << std::endl;
  std::cout << "C++11/CUDA Matrix transpose: B = A^T" << std::endl;

  prk::CUDA::info info;
  info.print();

  //////////////////////////////////////////////////////////////////////
  // Read and test input parameters
  //////////////////////////////////////////////////////////////////////

  int iterations;
  int order, tile_size;
  try {
      if (argc < 3) {
        throw "Usage: <# iterations> <matrix order>";
      }

      iterations  = std::atoi(argv[1]);
      if (iterations < 1) {
        throw "ERROR: iterations must be >= 1";
      }

      order = std::atoi(argv[2]);
      if (order <= 0) {
        throw "ERROR: Matrix Order must be greater than 0";
      } else if (order > prk::get_max_matrix_size()) {
        throw "ERROR: matrix dimension too large - overflow risk";
      }

#if TILED
      if (order % tile_dim != 0) {
          std::cout << "Sorry, but order (" << order << ") must be evenly divible by " << tile_dim
                    << " or the results are going to be wrong.\n";
      }
#else
      // default tile size for tiling of local transpose
      tile_size = 32;
      if (argc > 3) {
          tile_size = std::atoi(argv[3]);
          if (tile_size <= 0) tile_size = order;
          if (tile_size > order) tile_size = order;
          if (tile_size > 32) {
		  std::cout << "The results are probably going to be wrong; use tile_size<=32.\n";
	  }
      }
#endif
  }
  catch (const char * e) {
    std::cout << e << std::endl;
    return 1;
  }

  std::cout << "Number of iterations  = " << iterations << std::endl;
  std::cout << "Matrix order          = " << order << std::endl;
#if TILED
  std::cout << "Tile size             = " << tile_dim << std::endl;
#else
  std::cout << "Tile size             = " << tile_size << std::endl;
#endif

#if TILED
  dim3 dimGrid(order/tile_dim, order/tile_dim, 1);
  dim3 dimBlock(tile_dim, block_rows, 1);
#else
  dim3 dimGrid(prk::divceil(order,tile_size),prk::divceil(order,tile_size),1);
  dim3 dimBlock(tile_size, tile_size, 1);
#endif

  info.checkDims(dimBlock, dimGrid);

  //////////////////////////////////////////////////////////////////////
  // Allocate space for the input and transpose matrix
  //////////////////////////////////////////////////////////////////////

  const size_t nelems = (size_t)order * (size_t)order;

  double * h_a = prk::CUDA::malloc_host<double>(nelems);
  double * h_b = prk::CUDA::malloc_host<double>(nelems);

  // fill A with the sequence 0 to order^2-1
  for (int j=0; j<order; j++) {
    for (int i=0; i<order; i++) {
      h_a[j*order+i] = static_cast<double>(order*j+i);
      h_b[j*order+i] = static_cast<double>(0);
    }
  }

  // copy input from host to device
  double * d_a = prk::CUDA::malloc_device<double>(nelems);
  double * d_b = prk::CUDA::malloc_device<double>(nelems);

  prk::CUDA::copyH2D(d_a, h_a, nelems);
  prk::CUDA::copyH2D(d_b, h_b, nelems);

  double trans_time{0};

  for (int iter = 0; iter<=iterations; iter++) {

    if (iter==1) {
        prk::CUDA::sync();
        trans_time = prk::wtime();
    }

    transpose<<<dimGrid, dimBlock>>>(order, d_a, d_b);

    prk::CUDA::sync();
  }
  trans_time = prk::wtime() - trans_time;

  prk::CUDA::copyD2H(h_b, d_b, nelems);

#ifdef VERBOSE
  prk::CUDA::copyD2H(h_a, d_a, nelems);
#endif

  prk::CUDA::free(d_a);
  prk::CUDA::free(d_b);

  //////////////////////////////////////////////////////////////////////
  /// Analyze and output results
  //////////////////////////////////////////////////////////////////////

  const double addit = (iterations+1.) * (iterations/2.);
  double abserr(0);
  for (int j=0; j<order; j++) {
    for (int i=0; i<order; i++) {
      const size_t ij = (size_t)i*(size_t)order+(size_t)j;
      const size_t ji = (size_t)j*(size_t)order+(size_t)i;
      const double reference = static_cast<double>(ij)*(1.+iterations)+addit;
      abserr += prk::abs(h_b[ji] - reference);
    }
  }

#ifdef VERBOSE
  std::cout << "Sum of absolute differences: " << abserr << std::endl;
#endif

  prk::CUDA::free_host(h_a);
  prk::CUDA::free_host(h_b);

  const double epsilon = 1.0e-8;
  if (abserr < epsilon) {
    std::cout << "Solution validates" << std::endl;
    auto avgtime = trans_time/iterations;
    auto bytes = (size_t)order * (size_t)order * sizeof(double);
    std::cout << "Rate (MB/s): " << 1.0e-6 * (2L*bytes)/avgtime
              << " Avg time (s): " << avgtime << std::endl;
  } else {
#ifdef VERBOSE
    for (int i=0; i<order; i++) {
      for (int j=0; j<order; j++) {
        std::cout << "(" << i << "," << j << ") = " << h_a[i*order+j] << ", " << h_b[i*order+j] << "\n";
      }
    }
#endif
    std::cout << "ERROR: Aggregate squared error " << abserr
              << " exceeds threshold " << epsilon << std::endl;
    return 1;
  }

  return 0;
}


