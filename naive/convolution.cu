#include "fashion.h"

// Convolution layer initialization
// General structure remain unchanged
void Convolution::init(int minib, int Inputimage_h, int Inputimage_w,
                       int Inputimage_ch, int W_w_h, int W_ch) {
  std::default_random_engine generator;
  std::normal_distribution<float> distribution(0, 0.1);
  this->W_width_height = W_w_h;
  this->W_channel = W_ch;
  this->X_width = Inputimage_ch * Inputimage_h * Inputimage_w;
  this->X_height = minib;
  this->Inputimage_width = Inputimage_w;
  this->Inputimage_height = Inputimage_h;
  this->Inputimage_channel = Inputimage_ch;
  this->minibatch = minib;
  this->Outputimage_width = (Inputimage_width - W_width_height + 1);
  this->Outputimage_height = (Inputimage_height - W_width_height + 1);
  this->Outputimage_channel = W_channel / Inputimage_channel;
  this->Output_height = minib;
  this->Output_width =
      Outputimage_channel * Outputimage_height * Outputimage_width;
  this->Unroll_X_width = Outputimage_width * Outputimage_height;
  this->Unroll_X_height = Inputimage_channel * W_width_height * W_width_height;
  this->X.resize(
      minibatch * Inputimage_channel * Inputimage_height * Inputimage_width, 0);
  this->X_c.resize(
      minibatch * Inputimage_channel * Inputimage_height * Inputimage_width, 0);
  this->Unroll_X.resize(Inputimage_channel * W_width_height * W_width_height *
                            Outputimage_width * Outputimage_height,
                        0);
  this->Unroll_XT.resize(Outputimage_width * Outputimage_height *
                             Inputimage_channel * W_width_height *
                             W_width_height,
                         0);
  this->Unroll_X_c.resize(Inputimage_channel * W_width_height * W_width_height *
                              Outputimage_width * Outputimage_height,
                          0);
  this->W_c.resize(W_channel * W_width_height * W_width_height, 0.5);
  this->W.resize(Outputimage_channel * Inputimage_channel * W_width_height *
                     W_width_height,
                 0.5);
  this->WT.resize(Inputimage_channel * W_width_height * W_width_height *
                      Outputimage_channel,
                  0.5);
  for (int i = 0; i < W_channel * W_width_height * W_width_height; i++) {
    W_c[i] = distribution(generator);
  }
  for (int i = 0; i < W_channel * W_width_height * W_width_height; i++) {
    W[i] = distribution(generator);
  }
  this->Output_c.resize(minibatch * Outputimage_channel * Outputimage_width *
                            Outputimage_height,
                        0);
  this->Output.resize(minibatch * Outputimage_channel * Outputimage_width *
                          Outputimage_height,
                      0);
  this->Wgrad_c.resize(Outputimage_channel * Inputimage_channel *
                           W_width_height * W_width_height,
                       0);
  this->Wgrad.resize(Outputimage_channel * Inputimage_channel * W_width_height *
                         W_width_height,
                     0);
  this->WgradTmp.resize(Outputimage_channel * Inputimage_channel *
                            W_width_height * W_width_height,
                        0);
}

void Convolution::forward_GPU_naive() {
  dim3 threadsPerBlock(TILE_WIDTH, TILE_WIDTH);
  int bz = ceil((float)Outputimage_width / TILE_WIDTH) *
           ceil((float)Outputimage_height / TILE_WIDTH);
  if (bz == 0)
    bz = 1;
  dim3 numBlocks(minibatch, Outputimage_channel, bz);

  float *input_pointer = thrust::raw_pointer_cast(X.data());
  float *W_pointer = thrust::raw_pointer_cast(W.data());
  float *Output_pointer = thrust::raw_pointer_cast(Output.data());
  convLayer_forward_GPU_naive<<<numBlocks, threadsPerBlock>>>(
      input_pointer, W_pointer, Output_pointer, Inputimage_channel,
      Inputimage_height, Inputimage_width, Outputimage_width, W_width_height,
      Outputimage_channel);
}

void Convolution::backward_GPU_gemm() {
  float *Output_pointer = thrust::raw_pointer_cast(Output.data());
  float *X_pointer = thrust::raw_pointer_cast(X.data());
  float *Wgrad_pointer = thrust::raw_pointer_cast(Wgrad.data());
  float *WgradTmp_pointer = thrust::raw_pointer_cast(WgradTmp.data());
  float *W_pointer = thrust::raw_pointer_cast(W.data());
  float *WT_pointer = thrust::raw_pointer_cast(WT.data());
  float *Unroll_X_pointer = thrust::raw_pointer_cast(Unroll_X.data());
  float *Unroll_XT_pointer = thrust::raw_pointer_cast(Unroll_XT.data());
  dim3 threadsPerBlock(TILE_WIDTH, TILE_WIDTH);
  dim3 numBlocks(
      ceil((float)Outputimage_width * Outputimage_height / TILE_WIDTH),
      ceil((float)Outputimage_channel /
           TILE_WIDTH)); // bx = O_WIDTH, by = O_HEIGHT
  dim3 numBlocks_back_dE_dW(ceil((float)Unroll_X_height / TILE_WIDTH),
                            ceil((float)Outputimage_channel /
                                 TILE_WIDTH)); // bx = O_WIDTH, by = O_HEIGH
  dim3 numBlocks_back_dE_dX(
      ceil((float)Unroll_X_width / TILE_WIDTH),
      ceil((float)Unroll_X_height / TILE_WIDTH)); // bx = O_WIDTH, by = O_HEIGH
  int num_threads = Inputimage_channel * Outputimage_height * Outputimage_width;
  int num_blocks = ceil((float)num_threads / 1024);

  for (int i = 0; i < minibatch; i++) {
    // conv Wgrad
    // im2col

    unroll_Kernel<<<num_blocks, 1024>>>(Inputimage_channel, Inputimage_height,
                                        Inputimage_width, W_width_height,
                                        X_pointer, Unroll_X_pointer);

    // dL/dY * Unroll_X^t  = dY/dW
    transposeMatrix(Unroll_XT, Unroll_X, Unroll_X_height, Unroll_X_width);
    gemm_h<<<numBlocks_back_dE_dW, threadsPerBlock>>>(
        Output_pointer, Unroll_XT_pointer, WgradTmp_pointer,
        Outputimage_channel, Outputimage_height * Outputimage_width,
        Unroll_X_height, Outputimage_channel, Unroll_X_height);

    // sum Wgrad
    thrust::transform(Wgrad.begin(), Wgrad.end(), WgradTmp.begin(),
                      Wgrad.begin(), thrust::plus<float>());

    Output_pointer = Output_pointer + (Outputimage_channel *
                                       Outputimage_height * Outputimage_width);
    X_pointer =
        X_pointer + (Inputimage_channel * Inputimage_height * Inputimage_width);
  }

  // divide by MINIBATCH
  thrust::transform(Wgrad.begin(), Wgrad.end(), Wgrad.begin(), div_h());

  //// gradient descent
  // bx*tx = idata_width*idata*height
  int blockDim = ceil((float)Outputimage_channel * Unroll_X_height / 1024);
  grad_descent<<<blockDim, 1024>>>(W_pointer, Wgrad_pointer,
                                   Outputimage_channel * Unroll_X_height);
}

// We will use 2D thread blocks
// Each thread block computing a tile of elements in output feature map
// Tile is defined as TILE_WIDTH * TILE_WIDTH
// A total of 256 threads per block for TILE_WIDTH =16
// Blocks will be organized into 3D grid
// Grid.X : N samples in the batch
// Grid.Y : M output channel of feature maps
// Grid.Z : location of the output tile inside output feature map
//• depend on the number of tiles in the horizontal and vertical dim

//// number of horizontal tiles per output map
// int W_grid = W_out / TILE_WIDTH;
// number of vertical tiles per output map
// int H_grid = H_out / TILE_WIDTH;

__global__ void convLayer_forward_GPU_naive(float *X, float *W, float *Y, int C,
                                            int H_in, int W_in, int W_out,
                                            int K, int M) {
  int H_out = H_in - K + 1;
  int n, m, h, w, c, p, q;
  int W_grid = ceilf((float)W_out / TILE_WIDTH);
  if (W_grid == 0)
    W_grid = 1;
  n = blockIdx.x;
  m = blockIdx.y;
  h = (blockIdx.z / W_grid) * TILE_WIDTH + threadIdx.y;
  w = (blockIdx.z % W_grid) * TILE_WIDTH + threadIdx.x;
  // h and w is not center point, it's upper left corner point of Input image
  float acc = 0;
  for (c = 0; c < C; c++) { // sum over all input channels
    for (p = 0; p < K; p++) // loop over KxK filter
      for (q = 0; q < K; q++)
        if (h < H_out && w < W_out)
          acc = acc + X[n * (C * H_in * W_in) + c * (H_in * W_in) +
                        (h + p) * (W_in) + (w + q)] *
                          W[m * (C * K * K) + c * (K * K) + p * (K) + q];
  }
  if (h < H_out && w < W_out) {
    Y[n * (M * H_out * W_out) + m * (H_out * W_out) + h * (W_out) + w] = acc;
  }
}

__global__ void unroll_Kernel(int C, int H_in, int W_in, int K, float *X,
                              float *X_unroll) {
  int c, s, h_out, w_out, h_unroll, w_unroll, h_base, p, q;
  int t = blockIdx.x * 1024 + threadIdx.x;
  int H_out = H_in - K + 1;
  int W_out = W_in - K + 1;
  int W_unroll = H_out * W_out;

  if (t < C * W_unroll) {
    c = t / W_unroll;                 // if t < 28*28, c = 0  // output channel
    s = t % W_unroll;                 // output height * output width
    h_out = s / W_out;                // output height
    w_out = s % W_out;                // output width
    w_unroll = h_out * W_out + w_out; // in conv1, max 28*28(s)
    h_base = c * K * K;
    for (p = 0; p < K; p++)
      for (q = 0; q < K; q++) {
        h_unroll = h_base + p * K + q;
        if (c < C && (h_out + p) < H_in && (w_out + q) < W_in)
          X_unroll[h_unroll * (W_unroll) + w_unroll] =
              X[c * (W_in * H_in) + (h_out + p) * W_in + w_out + q];
      }
  }
}
