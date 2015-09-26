#include "GpuKdTree.h"
#include "cudpp\thrust_wrapper.h"
#include "cudpp\cudpp_wrapper.h"
#include "helper_math.h"
#include "cudpp\MergeSort.h"
namespace dfusion
{
#define CHECK_ZERO(a){if(a)printf("!!!error: %s=%d\n", #a, a);}
	texture<int, cudaTextureType1D, cudaReadModeElementType> g_mempool_tex;
	texture<float4, cudaTextureType1D, cudaReadModeElementType> g_ele_low_high_tex;
	__constant__ int g_ele_low_high_tex_off_d;

	typedef GpuKdTree::SplitInfo SplitInfo;
	//! used to update the left/right pointers and aabb infos after the node splits
	struct SetLeftAndRightAndAABB
	{
		int maxPoints;
		int nElements;

		SplitInfo* nodes;
		int* counts;
		int* labels;
		float4* aabbMin;
		float4* aabbMax;
		const float* x, *y, *z;
		const int* ix, *iy, *iz;

		__host__ __device__ void operator()(int i)
		{
			int index = labels[i];
			int right = 0;
			int left = counts[i];
			nodes[index].left = left;
			if (i < nElements - 1) {
				right = counts[i + 1];
			}
			else { // index==nNodes
				right = maxPoints;
			}
			nodes[index].right = right;
			aabbMin[index].x = x[ix[left]];
			aabbMin[index].y = y[iy[left]];
			aabbMin[index].z = z[iz[left]];
			aabbMax[index].x = x[ix[right - 1]];
			aabbMax[index].y = y[iy[right - 1]];
			aabbMax[index].z = z[iz[right - 1]];
		}
	};

	//! computes the scatter target address for the split operation, see Sengupta,Harris,Zhang,Owen: Scan Primitives for GPU Computing
	//! in my use case, this is about 2x as fast as thrust::partition
	struct set_addr3
	{
		const int* val_, *f_;

		int npoints_;
		__device__ int operator()(int id)
		{
			int nf = f_[npoints_ - 1] + (val_[npoints_ - 1]);
			int f = f_[id];
			int t = id - f + nf;
			return val_[id] ? f : t;
		}
	};

	//! just for convenience: access a float4 by an index in [0,1,2]
	//! (casting it to a float* and accessing it by the index is way slower...)
	__host__ __device__ __forceinline__ float get_value_by_index(const float4& f, int i)
	{
		switch (i) {
		case 0:
			return f.x;
		case 1:
			return f.y;
		default:
			return f.z;
		}
	}

	__device__ __forceinline__ float read_ftex(int id, int offset)
	{
		int v = tex1Dfetch(g_mempool_tex, id + offset);
		return *((float*)&v);
	}
	__device__ __forceinline__ float4 read_f4tex(int id, int offset)
	{
		return make_float4(read_ftex(id << 2, offset), read_ftex((id << 2) + 1, offset),
			read_ftex((id << 2) + 2, offset), read_ftex((id << 2) + 3, offset));
	}
	__device__ __forceinline__ float4 read_f4tex_f4(int offset)
	{
		return tex1Dfetch(g_ele_low_high_tex, g_ele_low_high_tex_off_d + offset);
	}
	__device__ __forceinline__ int read_itex(int id, int offset)
	{
		return tex1Dfetch(g_mempool_tex, id + offset);
	}
	__device__ __forceinline__ int2 read_i2tex(int id, int offset)
	{
		return make_int2(read_itex((id << 1), offset), read_itex((id << 1) + 1, offset));
	}

	//! - decide whether a node has to be split
	//! if yes:
	//! - allocate child nodes
	//! - set split axis as axis of maximum aabb length
	struct SplitNodes
	{
		typedef GpuKdTree::SplitInfo SplitInfo;
		int maxPointsPerNode;
		int* node_count;
		int* nodes_allocated;
		int* out_of_space;
		int* child1_;
		int* parent_;
		float4* aabbMin_;
		float4* aabbMax_;
		SplitInfo* splits_;

		// float4: aabbMin, aabbMax
		__device__ void operator()(int my_index) 
		{
			int child1 = child1_[my_index];
			SplitInfo& s = splits_[my_index];
			float4 aabbMin = aabbMin_[my_index];
			float4 aabbMax = aabbMax_[my_index];

			bool split_node = false;
			// first, each thread block counts the number of nodes that it needs to allocate...
			__shared__ int block_nodes_to_allocate;
			if (threadIdx.x == 0) block_nodes_to_allocate = 0;
			__syncthreads();

			// don't split if all points are equal
			// (could lead to an infinite loop, and doesn't make any sense anyway)
			bool all_points_in_node_are_equal = aabbMin.x == aabbMax.x 
				&& aabbMin.y == aabbMax.y && aabbMin.z == aabbMax.z;

			int offset_to_global = 0;

			// maybe this could be replaced with a reduction...
			if ((child1 == -1) && (s.right - s.left > maxPointsPerNode) 
				&& !all_points_in_node_are_equal) { // leaf node
				split_node = true;
				offset_to_global = atomicAdd(&block_nodes_to_allocate, 2);
			}

			__syncthreads();
			__shared__ int block_left;
			__shared__ bool enough_space;
			// ... then the first thread tries to allocate this many nodes...
			if (threadIdx.x == 0) {
				block_left = atomicAdd(node_count, block_nodes_to_allocate);
				enough_space = block_left + block_nodes_to_allocate < *nodes_allocated;
				// if it doesn't succeed, no nodes will be created by this block
				if (!enough_space) {
					atomicAdd(node_count, -block_nodes_to_allocate);
					*out_of_space = 1;
				}
			}

			__syncthreads();
			// this thread needs to split it's node && there was enough space for all the nodes
			// in this block.
			//(The whole "allocate-per-block-thing" is much faster than letting each element allocate
			// its space on its own, because shared memory atomics are A LOT faster than
			// global mem atomics!)
			if (split_node && enough_space) {
				int left = block_left + offset_to_global;

				splits_[left].left = s.left;
				splits_[left].right = s.right;
				splits_[left + 1].left = 0;
				splits_[left + 1].right = 0;

				// split axis/position: middle of longest aabb extent
				float4 aabbDim = aabbMax - aabbMin;
				int maxDim = 0;
				float maxDimLength =  aabbDim.x;
				float4 splitVal = (aabbMax + aabbMin);
				splitVal *= 0.5f;
				for (int i = 1; i <= 2; i++) {
					float val = get_value_by_index(aabbDim, i);
					if (val > maxDimLength) {
						maxDim = i;
						maxDimLength = val;
					}
				}
				s.split_dim = maxDim;
				s.split_val = get_value_by_index(splitVal, maxDim);

				child1_[my_index] = left;
				splits_[my_index] = s;

				parent_[left] = my_index;
				parent_[left + 1] = my_index;
				child1_[left] = -1;
				child1_[left + 1] = -1;
			}
		}
	};

	//! mark a point as belonging to the left or right child of its current parent
	//! called after parents are split
	struct MovePointsToChildNodes
	{
		typedef GpuKdTree::SplitInfo SplitInfo;
		MovePointsToChildNodes(int* child1, SplitInfo* splits, 
			float* x, float* y, float* z, int* ox, int* oy, 
			int* oz, int* lrx, int* lry, int* lrz)
		: child1_(child1), splits_(splits), x_(x), y_(y), z_(z), ox_(ox), 
		oy_(oy), oz_(oz), lrx_(lrx), lry_(lry), lrz_(lrz){}

		//  int dim;
		//  float threshold;
		int* child1_;
		SplitInfo* splits_;

		// coordinate values
		float* x_, *y_, *z_;
		// owner indices -> which node does the point belong to?
		int* ox_, *oy_, *oz_;
		// temp info: will be set to 1 of a point is moved to the right child node, 0 otherwise
		// (used later in the scan op to separate the points of the children into continuous ranges)
		int* lrx_, *lry_, *lrz_;

		__device__ void operator()(int index, int point_ind1, int point_ind2, int point_ind3)
		{
			int owner = ox_[index]; 
			int leftChild = child1_[owner];
			int split_dim;
			float dim_val1, dim_val2, dim_val3;
			SplitInfo split;
			lrx_[index] = 0;
			lry_[index] = 0;
			lrz_[index] = 0;
			// this element already belongs to a leaf node -> everything alright, no need to change anything
			if (leftChild == -1) 
				return;

			// otherwise: load split data, and assign this index to the new owner
			split = splits_[owner];
			split_dim = split.split_dim;
			switch (split_dim) {
			case 0:
				dim_val1 = x_[point_ind1];
				dim_val2 = x_[point_ind2];
				dim_val3 = x_[point_ind3];
				break;
			case 1:
				dim_val1 = y_[point_ind1];
				dim_val2 = y_[point_ind2];
				dim_val3 = y_[point_ind3];
				break;
			default:
				dim_val1 = z_[point_ind1];
				dim_val2 = z_[point_ind2];
				dim_val3 = z_[point_ind3];
				break;

			}

			int r1 = leftChild + (dim_val1 > split.split_val);
			ox_[index] = r1;
			int r2 = leftChild + (dim_val2 > split.split_val);
			oy_[index] = r2;
			oz_[index] = leftChild + (dim_val3 > split.split_val);

			lrx_[index] = (dim_val1 > split.split_val);
			lry_[index] = (dim_val2 > split.split_val);
			lrz_[index] = (dim_val3 > split.split_val);
		}
	};
	__global__ void splitNode_kernel(SplitNodes s, int n)
	{
		int tid = threadIdx.x + blockIdx.x*blockDim.x;
		if (tid < n)
			s(tid);
	}

	__global__ void movePointsToChildNodes_kernel(MovePointsToChildNodes s, 
		int* index_x, int* index_y, int* index_z, int n)
	{
		int tid = threadIdx.x + blockIdx.x*blockDim.x;
		if (tid < n)
		{
			s(tid, index_x[tid], index_y[tid], index_z[tid]);
		}
	}

	__global__ void for_each_SetLeftAndRightAndAABB_kernel(SetLeftAndRightAndAABB s, int n)
	{
		int tid = threadIdx.x + blockIdx.x*blockDim.x;
		if (tid < n)
			s(tid);
	}

	__global__ void collect_aabb_kernel(float4* aabb_min, float4* aabb_max,
		const float* x, const int* ix,
		const float* y, const int* iy,
		const float* z, const int* iz, int n)
	{
		int tid = threadIdx.x + blockIdx.x*blockDim.x;
		if (tid == 0)
		{
			aabb_min[0] = make_float4(x[ix[0]], y[iy[0]], z[iz[0]], 0);
			aabb_max[0] = make_float4(x[ix[n-1]], y[iy[n-1]], z[iz[n-1]], 0);
		}
	}

	__global__ void set_addr3_kernel(set_addr3 sa, int* out, int n)
	{
		int tid = threadIdx.x + blockIdx.x*blockDim.x;
		if (tid < n)
		{
			out[tid] = sa(tid);
		}
	}

	template<class T>
	__global__ void resize_vec_kernel(const T* oldVec, T* newVec, int oldSize, int newSize, T val)
	{
		int tid = threadIdx.x + blockIdx.x*blockDim.x;
		if (tid < newSize)
		{
			if (tid < oldSize)
				newVec[tid] = oldVec[tid];
			else
				newVec[tid] = val;
		}
	}

	__global__ void init_data_kernel(
		const void* points_in, int points_in_stride,
		float4* points_out, float* point_x, float* point_y, float* point_z,
		float* tmp_pt_x, float* tmp_pt_y, float* tmp_pt_z,
		int* index_x, int* index_y, int* index_z, int nPoints,
		int* child1, int* parent, SplitInfo* splits, int prealloc)
	{
		int tid = threadIdx.x + blockIdx.x*blockDim.x;
		if (tid < nPoints)
		{
			float4 xyz = *(const float4*)((const char*)points_in + points_in_stride*tid);
			points_out[tid] = xyz;
			point_x[tid] = xyz.x;
			point_y[tid] = xyz.y;
			point_z[tid] = xyz.z;
			tmp_pt_x[tid] = xyz.x;
			tmp_pt_y[tid] = xyz.y;
			tmp_pt_z[tid] = xyz.z;
			index_x[tid] = tid;
			index_y[tid] = tid;
			index_z[tid] = tid;
		}
		if (tid < prealloc)
		{
			child1[tid] = -1;
			parent[tid] = -1;

			GpuKdTree::SplitInfo s;
			s.left = 0;
			s.right = 0;
			if (tid == 0)
				s.right = nPoints;
			splits[tid] = s;
		}
	}

	GpuKdTree::GpuKdTree()
	{
		nInputPoints_ = 0;
		nAllocatedPoints_ = 0;
		max_leaf_size_ = 0;
		prealloc_ = 0;

		// mempool_.ptr(), num = nInputPoints_
		input_points_ptr_ = nullptr;
		points_ptr_ = nullptr;
		aabb_min_ptr_ = nullptr;
		aabb_max_ptr_ = nullptr;
		points_x_ptr_ = nullptr;
		points_y_ptr_ = nullptr;
		points_z_ptr_ = nullptr;
		splits_ptr_ = nullptr;
		child1_ptr_ = nullptr;
		parent_ptr_ = nullptr;
		index_x_ptr_ = nullptr;
		index_y_ptr_ = nullptr;
		index_z_ptr_ = nullptr;
		owner_x_ptr_ = nullptr;
		owner_y_ptr_ = nullptr;
		owner_z_ptr_ = nullptr;
		leftright_x_ptr_ = nullptr;
		leftright_y_ptr_ = nullptr;
		leftright_z_ptr_ = nullptr;
		tmp_index_ptr_ = nullptr;
		tmp_owners_ptr_ = nullptr;
		tmp_misc_ptr_ = nullptr;
		allocation_info_ptr_ = nullptr;
	}

	void GpuKdTree::buildTree(const void* points, int points_stride, int n, int max_leaf_size)
	{
		// memory allocation
		allocateMemPool(n, max_leaf_size);
		
		// data initialization
		// input_points
		{
			dim3 block(256);
			int num = max(nInputPoints_, prealloc_);
			dim3 grid(divUp(num, block.x));
			init_data_kernel << <grid, block >> >(points, points_stride,
				input_points_ptr_, points_x_ptr_, points_y_ptr_,points_z_ptr_,
				tmp_pt_x_ptr_, tmp_pt_y_ptr_, tmp_pt_z_ptr_,
				index_x_ptr_, index_y_ptr_, index_z_ptr_, nInputPoints_,
				child1_ptr_, parent_ptr_, splits_ptr_, prealloc_);
		}
		// allocation info
		cudaSafeCall(cudaMemcpy(allocation_info_ptr_, allocation_info_host_.data(),
			allocation_info_host_.size()*sizeof(int), cudaMemcpyHostToDevice));
		
		// create sorted index list -> can be used to compute AABBs in O(1)
		thrust_wrapper::sort_by_key(tmp_pt_x_ptr_, index_x_ptr_, nInputPoints_);
		thrust_wrapper::sort_by_key(tmp_pt_y_ptr_, index_y_ptr_, nInputPoints_);
		thrust_wrapper::sort_by_key(tmp_pt_z_ptr_, index_z_ptr_, nInputPoints_);

		// bounding box info
		{
			dim3 block(1);
			dim3 grid(1);
			collect_aabb_kernel << <grid, block >> >(aabb_min_ptr_, aabb_max_ptr_,
				points_x_ptr_, index_x_ptr_, points_y_ptr_, index_y_ptr_,
				points_z_ptr_, index_z_ptr_, nInputPoints_);
		}
		
		int last_node_count = 0;
		for (int i = 0;; i++) 
		{
			SplitNodes sn;
			sn.maxPointsPerNode = max_leaf_size_;
			sn.node_count = allocation_info_ptr_ + NodeCount;
			sn.nodes_allocated = allocation_info_ptr_ + NodesAllocated;
			sn.out_of_space = allocation_info_ptr_ + OutOfSpace;
			sn.child1_ = child1_ptr_;
			sn.parent_ = parent_ptr_;
			sn.splits_ = splits_ptr_;
			sn.aabbMin_ = aabb_min_ptr_;
			sn.aabbMax_ = aabb_max_ptr_;
			if (last_node_count)
			{
				dim3 block(256);
				dim3 grid(divUp(last_node_count, block.x));
				splitNode_kernel << <grid, block >> >(sn, last_node_count);
			}

			// copy allocation info to host
			cudaSafeCall(cudaMemcpy(allocation_info_host_.data(), allocation_info_ptr_,
				allocation_info_host_.size()*sizeof(int), cudaMemcpyDeviceToHost));

			if (last_node_count == allocation_info_host_[NodeCount]) // no more nodes were split -> done
				break;
			
			last_node_count = allocation_info_host_[NodeCount];

			// a node was un-splittable due to a lack of space
			if (allocation_info_host_[OutOfSpace] == 1) 
			{
				printf("GpuKdTree::buildTree(): warning: dynamic resize needed!\n");
				resize_node_vectors(allocation_info_host_[NodesAllocated] * 2);
				allocation_info_host_[OutOfSpace] = 0;
				allocation_info_host_[NodesAllocated] *= 2;
				cudaSafeCall(cudaMemcpy(allocation_info_ptr_, allocation_info_host_.data(),
					allocation_info_host_.size()*sizeof(int), cudaMemcpyHostToDevice));
			}

			// foreach point: point was in node that was split?move it to child (leaf) node : do nothing
			MovePointsToChildNodes sno(child1_ptr_, splits_ptr_, points_x_ptr_,
				points_y_ptr_, points_z_ptr_, owner_x_ptr_, owner_y_ptr_,
				owner_z_ptr_, leftright_x_ptr_, leftright_y_ptr_, leftright_z_ptr_
				);
			{
				dim3 block(256);
				dim3 grid(divUp(nInputPoints_, block.x));
				movePointsToChildNodes_kernel << <grid, block >> >(sno, 
					index_x_ptr_, index_y_ptr_, index_z_ptr_, nInputPoints_);
			}

			// move points around so that each leaf node's points are continuous
			separate_left_and_right_children(index_x_ptr_, owner_x_ptr_, tmp_index_ptr_, 
				tmp_owners_ptr_, leftright_x_ptr_);
			cudaMemcpy(index_x_ptr_, tmp_index_ptr_, nInputPoints_*sizeof(int), cudaMemcpyDeviceToDevice);
			cudaMemcpy(owner_x_ptr_, tmp_owners_ptr_, nInputPoints_*sizeof(int), cudaMemcpyDeviceToDevice);
			separate_left_and_right_children(index_y_ptr_, owner_y_ptr_, tmp_index_ptr_, tmp_owners_ptr_,
				leftright_y_ptr_, false);
			cudaMemcpy(index_y_ptr_, tmp_index_ptr_, nInputPoints_*sizeof(int), cudaMemcpyDeviceToDevice);
			separate_left_and_right_children(index_z_ptr_, owner_z_ptr_, tmp_index_ptr_, tmp_owners_ptr_, 
				leftright_z_ptr_, false);
			cudaMemcpy(index_z_ptr_, tmp_index_ptr_, nInputPoints_*sizeof(int), cudaMemcpyDeviceToDevice);

			// calculate new AABB etc
			update_leftright_and_aabb(points_x_ptr_, points_y_ptr_, points_z_ptr_, index_x_ptr_,
				index_y_ptr_, index_z_ptr_, owner_x_ptr_, splits_ptr_, aabb_min_ptr_, aabb_max_ptr_);
		} 
		
		thrust_wrapper::gather(input_points_ptr_, index_x_ptr_, points_ptr_, nInputPoints_);

	}

	void GpuKdTree::allocateMemPool(int nInputPoints, int maxLeafSize)
	{
		nInputPoints_ = nInputPoints;
		max_leaf_size_ = maxLeafSize;
		if (nAllocatedPoints_ < nInputPoints_)
		{
			nAllocatedPoints_ = ceil(nInputPoints_ * 1.5);
			prealloc_ = divUp(nAllocatedPoints_ * 16, max_leaf_size_);
			mempool_.create(
				nAllocatedPoints_*sizeof(float4) * 2 +
				prealloc_ * sizeof(float4) * 2 +
				nAllocatedPoints_ * sizeof(float) * 6 +
				prealloc_ * sizeof(SplitInfo) +
				prealloc_ * sizeof(int) * 2 +
				nAllocatedPoints_ * sizeof(int) * 12 +
				4
				);
			printf("GpuKdTree: re-allocate\n");

			// assigne buffers
			input_points_ptr_ = (float4*)mempool_.ptr();
			points_ptr_ = input_points_ptr_ + nAllocatedPoints_;
			aabb_min_ptr_ = points_ptr_ + nAllocatedPoints_;
			aabb_max_ptr_ = aabb_min_ptr_ + prealloc_;
			points_x_ptr_ = (float*)(aabb_max_ptr_ + prealloc_);
			points_y_ptr_ = points_x_ptr_ + nAllocatedPoints_;
			points_z_ptr_ = points_y_ptr_ + nAllocatedPoints_;
			tmp_pt_x_ptr_ = points_z_ptr_ + nAllocatedPoints_;
			tmp_pt_y_ptr_ = tmp_pt_x_ptr_ + nAllocatedPoints_;
			tmp_pt_z_ptr_ = tmp_pt_y_ptr_ + nAllocatedPoints_;
			splits_ptr_ = (SplitInfo*)(tmp_pt_z_ptr_ + nAllocatedPoints_);
			child1_ptr_ = (int*)(splits_ptr_+prealloc_);
			parent_ptr_ = child1_ptr_ + prealloc_;
			index_x_ptr_ = parent_ptr_ + prealloc_;
			index_y_ptr_ = index_x_ptr_ + nAllocatedPoints_;
			index_z_ptr_ = index_y_ptr_ + nAllocatedPoints_;
			owner_x_ptr_ = index_z_ptr_ + nAllocatedPoints_;
			owner_y_ptr_ = owner_x_ptr_ + nAllocatedPoints_;
			owner_z_ptr_ = owner_y_ptr_ + nAllocatedPoints_;
			leftright_x_ptr_ = owner_z_ptr_ + nAllocatedPoints_;
			leftright_y_ptr_ = leftright_x_ptr_ + nAllocatedPoints_;
			leftright_z_ptr_ = leftright_y_ptr_ + nAllocatedPoints_;
			tmp_index_ptr_ = leftright_z_ptr_ + nAllocatedPoints_;
			tmp_owners_ptr_ = tmp_index_ptr_ + nAllocatedPoints_;
			tmp_misc_ptr_ = tmp_owners_ptr_ + nAllocatedPoints_;
			allocation_info_ptr_ = tmp_misc_ptr_ + nAllocatedPoints_;

			// bind src to texture
			size_t offset;
			cudaChannelFormatDesc desc_int = cudaCreateChannelDesc<int>();
			cudaBindTexture(&offset, &g_mempool_tex, mempool_.ptr(), &desc_int,
				mempool_.size()*sizeof(int));
			CHECK_ZERO(offset);
			cudaChannelFormatDesc desc_f4 = cudaCreateChannelDesc<float4>();
			cudaSafeCall(cudaBindTexture(&offset, &g_ele_low_high_tex, points_ptr_, &desc_f4,
				aabb_max_offset_byte()-points_offset_byte()+prealloc_*sizeof(float4)));
			int offset_f4 = offset / sizeof(float4);
			cudaSafeCall(cudaMemcpyToSymbol(g_ele_low_high_tex_off_d, &offset_f4, sizeof(int)));
		}


		allocation_info_host_.resize(3);
		allocation_info_host_[GpuKdTree::NodeCount] = 1;
		allocation_info_host_[GpuKdTree::NodesAllocated] = prealloc_;
		allocation_info_host_[GpuKdTree::OutOfSpace] = 0;

		// reset mem
		cudaMemset(mempool_.ptr(), 0, mempool_.size()*mempool_.elem_size);
	}

	namespace KdTreeCudaPrivate
	{	
		//! implementation of L2 distance for the CUDA kernels
		struct CudaL2Distance
		{
			static float __host__ __device__ __forceinline__ axisDist(float a, float b)
			{
				return (a - b)*(a - b);
			}

			static float __host__ __device__ __forceinline__ dist(float4 a, float4 b)
			{
				return (a.x - b.x)*(a.x - b.x) + (a.y - b.y)*(a.y - b.y) + (a.z - b.z)*(a.z - b.z);
			}
		};

		//! result set for the 1nn search. Doesn't do any global memory accesses on its own,
		template< typename DistanceType >
		struct SingleResultSet
		{
			int bestIndex;
			DistanceType bestDist;

			__device__ __host__ SingleResultSet() : 
				bestIndex(-1), bestDist(INFINITY){ }

			__device__ inline float worstDist()
			{
				return bestDist;
			}

			__device__ inline void insert(int index, DistanceType dist)
			{
				if (dist <= bestDist) {
					bestIndex = index;
					bestDist = dist;
				}
			}

			DistanceType* resultDist;
			int* resultIndex;

			__device__ inline void setResultLocation(DistanceType* dists, int* index, int thread)
			{
				resultDist = dists + thread;
				resultIndex = index + thread;
				resultDist[0] = INFINITY;
				resultIndex[0] = -1;
			}

			__device__ inline void finish()
			{
				resultDist[0] = bestDist;
				resultIndex[0] = bestIndex;
			}
		};

		template< typename DistanceType >
		struct GreaterThan
		{
			__device__
			bool operator()(DistanceType a, DistanceType b)
			{
				return a>b;
			}
		};

		// using this and the template uses 2 or 3 registers more than the direct implementation in the kNearestKernel, but
		// there is no speed difference.
		// Setting useHeap as a template parameter leads to a whole lot of things being
		// optimized away by nvcc.
		// Register counts are the same as when removing not-needed variables in explicit specializations
		// and the "if( useHeap )" branches are eliminated at compile time.
		// The downside of this: a bit more complex kernel launch code.
		template< typename DistanceType>
		struct KnnResultSet
		{
			int foundNeighbors;
			DistanceType largestHeapDist;
			int maxDistIndex;
			const int k;
			const bool sorted;

			__device__ __host__ KnnResultSet(int knn, bool sortResults) : 
				foundNeighbors(0), largestHeapDist(INFINITY), k(knn), sorted(sortResults){ }

			__device__ inline DistanceType worstDist()
			{
				return largestHeapDist;
			}

			__device__ inline void insert(int index, DistanceType dist)
			{
				if (foundNeighbors < k) {
					resultDist[foundNeighbors] = dist;
					resultIndex[foundNeighbors] = index;
					if (foundNeighbors == k - 1)
						findLargestDistIndex();
					foundNeighbors++;
				}
				else if (dist < largestHeapDist) {
					resultDist[maxDistIndex] = dist;
					resultIndex[maxDistIndex] = index;
					findLargestDistIndex();
				}
			}

			__device__ void findLargestDistIndex()
			{
				largestHeapDist = resultDist[0];
				maxDistIndex = 0;
				for (int i = 1; i<k; i++)
				if (resultDist[i] > largestHeapDist) {
					maxDistIndex = i;
					largestHeapDist = resultDist[i];
				}
			}

			float* resultDist;
			int* resultIndex;

			__device__ inline void setResultLocation(DistanceType* dists, int* index, int thread)
			{
				resultDist = dists + thread*k;
				resultIndex = index + thread*k;
				for (int i = 0; i < k; i++) {
					resultDist[i] = INFINITY;
					resultIndex[i] = -1;
				}
			}

			__host__ __device__ inline void finish()
			{
				if (sorted) {
					//if (!useHeap) flann::cuda::heap::make_heap(resultDist, resultIndex, k, 
					//	GreaterThan<DistanceType>());
					//for (int i = k - 1; i>0; i--) {
					//	swap(resultDist[0], resultDist[i]);
					//	swap(resultIndex[0], resultIndex[i]);
					//	flann::cuda::heap::sift_down(resultDist, resultIndex, 0, i, GreaterThan<DistanceType>());
					//}
				}
			}
		};

		template< typename GPUResultSet>
		__device__ void searchNeighbors(const float4& q,
			GPUResultSet& result,
			int split_off, int child1_off, int parent_off, 
			int ele_off, int low_off, int high_off, int index_x_off,
			int low_off2ele, int high_off2ele
			)
		{
			bool backtrack = false;
			int lastNode = -1;
			int current = 0;

			GpuKdTree::SplitInfo split;
			while (true) {
				if (current == -1) break;
				split = read_i2tex(current, split_off);

				float diff1 = (split.split_dim == 0)*(q.x - split.split_val)
					+ (split.split_dim == 1)*(q.y - split.split_val)
					+ (split.split_dim == 2)*(q.z - split.split_val);

				// children are next to each other: leftChild+1 == rightChild
				int leftChild = read_itex(current, child1_off);
				int bestChild = leftChild +(diff1 >= 0);
				int otherChild = leftChild +(diff1 < 0);

				if (!backtrack) {
					/* If this is a leaf node, then do check and return. */
					if (leftChild == -1) {
						for (int i = split.left; i < split.right; ++i) {
							float dist = CudaL2Distance::dist(read_f4tex_f4(i), q);
							result.insert(read_itex(i, index_x_off), dist);
						}

						backtrack = true;
						lastNode = current;
						current = read_itex(current, parent_off);
					}
					else { // go to closer child node
						lastNode = current;
						current = bestChild;
					}
				}
				else { 
					// continue moving back up the tree or visit far node?
					// minimum possible distance between query point and a point inside the AABB
					float4 aabbMin = read_f4tex_f4(otherChild + low_off2ele);
					float4 aabbMax = read_f4tex_f4(otherChild + high_off2ele);
					float mindistsq = (q.x < aabbMin.x) * CudaL2Distance::axisDist(q.x, aabbMin.x)
						+ (q.x > aabbMax.x) * CudaL2Distance::axisDist(q.x, aabbMax.x)
						+ (q.y < aabbMin.y) * CudaL2Distance::axisDist(q.y, aabbMin.y)
						+ (q.y > aabbMax.y) * CudaL2Distance::axisDist(q.y, aabbMax.y)
						+ (q.z < aabbMin.z) * CudaL2Distance::axisDist(q.z, aabbMin.z)
						+ (q.z > aabbMax.z) * CudaL2Distance::axisDist(q.z, aabbMax.z);

					//  the far node was NOT the last node (== not visited yet) 
					//  AND there could be a closer point in it
					if ((lastNode == bestChild) && (mindistsq <= result.worstDist())) 
					{
						lastNode = current;
						current = otherChild;
						backtrack = false;
					}
					else {
						lastNode = current;
						current = read_itex(current, parent_off);
					}
				}
			}
		}

		template< typename GPUResultSet>
		__global__ void nearestKernel(const float4* query,
			int* resultIndex, float* resultDist,
			int querysize, GPUResultSet result,
			int split_off, int child1_off, int parent_off, 
			int ele_off, int low_off, int high_off, int index_x_off,
			int low_off2ele, int high_off2ele
			)
		{
			typedef float DistanceType;
			typedef float ElementType;
			//                  typedef DistanceType float;
			int tid = blockDim.x*blockIdx.x + threadIdx.x;

			if (tid >= querysize) return;

			float4 q = query[tid];

			result.setResultLocation(resultDist, resultIndex, tid);
			searchNeighbors(q, result, split_off, child1_off, parent_off, 
				ele_off, low_off, high_off, index_x_off,
				low_off2ele, high_off2ele);
			result.finish();
		}
	}

	void GpuKdTree::knnSearchGpu(const float4* queries, int* indices, float* dists, size_t knn, size_t n) const
	{
		if (n == 0)
			return;
		int threadsPerBlock = 256;
		int blocksPerGrid = divUp(n, threadsPerBlock);
		bool sorted = false;

		int split_off = splits_offset_byte() / 4;
		int child1_off = child1_offset_byte() / 4;
		int parent_off = parent_offset_byte() / 4;
		int ele_off = points_offset_byte() / 4;
		int low_off = aabb_min_offset_byte() / 4;
		int high_off = aabb_max_offset_byte() / 4;
		int index_x_off = index_x_offset_byte() / 4;
		int low_off2ele = (low_off - ele_off) / 4;
		int high_off2ele = (high_off - ele_off) / 4;

		if (knn == 1) {
			KdTreeCudaPrivate::nearestKernel << <blocksPerGrid, threadsPerBlock >> > (
				queries,
				indices,
				dists,
				n, 
				KdTreeCudaPrivate::SingleResultSet<float>(),
				split_off, child1_off, parent_off, ele_off, low_off, high_off, index_x_off,
				low_off2ele, high_off2ele
				);
		}
		else {
			KdTreeCudaPrivate::nearestKernel << <blocksPerGrid, threadsPerBlock >> > (
				queries,
				indices,
				dists,
				n,
				KdTreeCudaPrivate::KnnResultSet<float>(knn, sorted),
				split_off, child1_off, parent_off, ele_off, low_off, high_off, index_x_off,
				low_off2ele, high_off2ele
				);
		}
	}

	void GpuKdTree::update_leftright_and_aabb(
		const float* x,
		const float* y,
		const float* z,
		const int* ix,
		const int* iy,
		const int* iz,
		const int* owners,
		SplitInfo* splits,
		float4* aabbMin,
		float4* aabbMax)
	{
		int* labelsUnique = tmp_owners_ptr_;
		int* countsUnique = tmp_index_ptr_;
		// assume: points of each node are continuous in the array

		// find which nodes are here, and where each node's points begin and end
		int unique_labels = thrust_wrapper::unique_counting_by_key_copy(
			owners, 0, labelsUnique, countsUnique, nInputPoints_);

		// update the info
		SetLeftAndRightAndAABB s;
		s.maxPoints = nInputPoints_;
		s.nElements = unique_labels;
		s.nodes = splits;
		s.counts = countsUnique;
		s.labels = labelsUnique;
		s.x = x;
		s.y = y;
		s.z = z;
		s.ix = ix;
		s.iy = iy;
		s.iz = iz;
		s.aabbMin = aabbMin;
		s.aabbMax = aabbMax;

		dim3 block(256);
		dim3 grid(divUp(unique_labels, block.x));
		for_each_SetLeftAndRightAndAABB_kernel << <grid, block >> >(s, unique_labels);
		cudaSafeCall(cudaGetLastError());
	}

	//! Separates the left and right children of each node into continuous parts of the array.
	//! More specifically, it seperates children with even and odd node indices because nodes are always
	//! allocated in pairs -> child1==child2+1 -> child1 even and child2 odd, or vice-versa.
	//! Since the split operation is stable, this results in continuous partitions
	//! for all the single nodes.
	//! (basically the split primitive according to sengupta et al)
	//! about twice as fast as thrust::partition
	void GpuKdTree::separate_left_and_right_children(
		int* key_in,
		int* val_in,
		int* key_out,
		int* val_out,
		int* left_right_marks,
		bool scatter_val_out)
	{
		int* f_tmp = val_out;
		int* addr_tmp = tmp_misc_ptr_;

		thrust_wrapper::exclusive_scan(left_right_marks, f_tmp, nInputPoints_);

		set_addr3 sa;
		sa.val_ = left_right_marks;
		sa.f_ = f_tmp;
		sa.npoints_ = nInputPoints_;
		{
			dim3 block(256);
			dim3 grid(divUp(nInputPoints_, block.x));
			set_addr3_kernel << <grid, block >> >(sa, addr_tmp, nInputPoints_);
			cudaSafeCall(cudaGetLastError());
		}
		thrust_wrapper::scatter(key_in, addr_tmp, key_out, nInputPoints_);
		if (scatter_val_out) 
			thrust_wrapper::scatter(val_in, addr_tmp, val_out, nInputPoints_);
	}

	template<class T>
	static void resize_vec(DeviceArray<T>& oldVec, int new_size, T val)
	{
		DeviceArray<T> newVec;
		newVec.create(new_size);

		dim3 block(256);
		dim3 grid(divUp(new_size, block.x));
		resize_vec_kernel<<<grid, block>>>(oldVec.ptr(), newVec.ptr(), oldVec.size(), newVec.size(), val);
	}

	//! allocates additional space in all the node-related vectors.
	//! new_size elements will be added to all vectors.
	void GpuKdTree::resize_node_vectors(size_t new_size)
	{
		throw std::exception("not supported!");
		//resize_vec(child1_, new_size, -1);
		//resize_vec(parent_, new_size, -1);
		//SplitInfo s;
		//s.left = 0;
		//s.right = 0;
		//resize_vec(splits_, new_size, s);
		//float4 f = make_float4(0,0,0,0);
		//resize_vec(aabb_min_, new_size, f);
		//resize_vec(aabb_max_, new_size, f);
	}
}