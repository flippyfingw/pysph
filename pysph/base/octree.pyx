#cython: embedsignature=True

from nnps_base cimport *

from libc.stdlib cimport malloc, free
from libc.stdint cimport uint64_t
from libcpp.vector cimport vector

cimport cython
from cython.operator cimport dereference as deref, preincrement as inc
from cpython cimport PyObject, Py_XINCREF, Py_XDECREF

DEF EPS_MAX = 1e-3
DEF MACHINE_EPS = 1e-14

cdef class OctreeNode:
    def __init__(self):
        pass

    cdef void wrap_node(self, cOctreeNode* node):
        self._node = node
        self.hmax = node.hmax
        self.length = node.length
        self.is_leaf = node.is_leaf
        self.level = node.level

        cdef DoubleArray py_xmin = DoubleArray(3)
        py_xmin.data[0] = self._node.xmin[0]
        py_xmin.data[1] = self._node.xmin[1]
        py_xmin.data[2] = self._node.xmin[2]
        self.xmin = py_xmin

    cpdef UIntArray get_indices(self):
        if not self._node.is_leaf:
            return UIntArray()
        return <UIntArray>self._node.indices

    cpdef OctreeNode get_parent(self):
        if self._node.parent == NULL:
            return None
        cdef OctreeNode parent = OctreeNode()
        parent.wrap_node(self._node.parent)
        return parent

    cpdef list get_children(self):
        if self._node.is_leaf:
            return []
        cdef int i
        cdef list py_children = [OctreeNode() for i in range(8)]
        for i from 0<=i<8:
            (<OctreeNode>py_children[i]).wrap_node(self._node.children[i])
        return py_children

    cpdef plot(self, ax, color="k"):
        cdef int i, j, k
        cdef double x, y, z
        cdef list ax_points = [0,0]

        for i from 0<=i<2:
            for j from 0<=j<2:
                x = self.xmin.data[0] + i*self.length
                y = self.xmin.data[1] + j*self.length
                for k from 0<=k<2:
                    ax_points[k] = self.xmin.data[2] + k*self.length

                ax.plot([x,x], [y,y], zs=ax_points[:], color=color)

        for i from 0<=i<2:
            for k from 0<=k<2:
                x = self.xmin.data[0] + i*self.length
                z = self.xmin.data[2] + k*self.length
                for j from 0<=j<2:
                    ax_points[j] = self.xmin.data[1] + j*self.length

                ax.plot([x,x], ax_points[:], zs=[z,z], color=color)

        for j from 0<=j<2:
            for k from 0<=k<2:
                y = self.xmin.data[1] + j*self.length
                z = self.xmin.data[2] + k*self.length
                for i from 0<=i<2:
                    ax_points[i] = self.xmin.data[0] + i*self.length

                ax.plot(ax_points[:], [y,y], zs=[z,z], color=color)

cdef class Octree:
    def __init__(self, int leaf_max_particles, double radius_scale):
        self.leaf_max_particles = leaf_max_particles
        self.radius_scale = radius_scale
        self.depth = 0
        self.tree = NULL

    def __dealloc__(self):
        self._delete_tree(self.tree)


    @cython.cdivision(True)
    cdef inline void _calculate_domain(self, NNPSParticleArrayWrapper pa):
        cdef int num_particles = pa.get_number_of_particles()

        cdef double xmin = DBL_MAX
        cdef double ymin = DBL_MAX
        cdef double zmin = DBL_MAX

        cdef double xmax = -DBL_MAX
        cdef double ymax = -DBL_MAX
        cdef double zmax = -DBL_MAX

        cdef double hmax = 0

        for i from 0<=i<num_particles:
            xmax = fmax(xmax, pa.x.data[i])
            ymax = fmax(ymax, pa.y.data[i])
            zmax = fmax(zmax, pa.z.data[i])

            xmin = fmin(xmin, pa.x.data[i])
            ymin = fmin(ymin, pa.y.data[i])
            zmin = fmin(zmin, pa.z.data[i])

            hmax = fmax(hmax, pa.h.data[i])

        self.xmin[0] = xmin
        self.xmin[1] = ymin
        self.xmin[2] = zmin

        self.xmax[0] = xmax
        self.xmax[1] = ymax
        self.xmax[2] = zmax

        self.hmax = hmax

        cdef double x_length = self.xmax[0] - self.xmin[0]
        cdef double y_length = self.xmax[1] - self.xmin[1]
        cdef double z_length = self.xmax[2] - self.xmin[2]

        self.length = fmax(x_length, fmax(y_length, z_length))

        cdef double eps = (MACHINE_EPS/self.length)*fmax(self.length,
                fmax(fmax(fabs(self.xmin[0]), fabs(self.xmin[1])), fabs(self.xmin[2])))

        self.xmin[0] -= self.length*eps
        self.xmin[1] -= self.length*eps
        self.xmin[2] -= self.length*eps

        self.length *= (1 + 2*eps)

        cdef double xmax_padded = self.xmin[0] + self.length
        cdef double ymax_padded = self.xmin[1] + self.length
        cdef double zmax_padded = self.xmin[2] + self.length

        self._eps0 = (2*MACHINE_EPS/self.length)*fmax(self.length,
                fmax(fmax(fabs(xmax_padded), fabs(ymax_padded)), fabs(zmax_padded)))

    cdef inline cOctreeNode* _new_node(self, double* xmin, double length,
            double hmax = 0, int level = 0, cOctreeNode* parent = NULL,
            int num_particles = 0, bint is_leaf = False) nogil:
        """Create a new cOctreeNode"""
        cdef cOctreeNode* node = <cOctreeNode*> malloc(sizeof(cOctreeNode))

        node.xmin[0] = xmin[0]
        node.xmin[1] = xmin[1]
        node.xmin[2] = xmin[2]

        node.length = length
        node.hmax = hmax
        node.num_particles = num_particles
        node.is_leaf = is_leaf
        node.level = level

        node.parent = parent
        node.indices = NULL

        cdef int i

        for i from 0<=i<8:
            node.children[i] = NULL

        return node

    cdef inline void _delete_tree(self, cOctreeNode* node):
        """Delete octree"""
        cdef int i, j, k
        cdef cOctreeNode* temp[8]

        for i from 0<=i<8:
            temp[i] = node.children[i]

        Py_XDECREF(<PyObject*>node.indices)
        free(node)

        for i from 0<=i<8:
            if temp[i] == NULL:
                return
            else:
                self._delete_tree(temp[i])

    @cython.cdivision(True)
    cdef int _c_build_tree(self, NNPSParticleArrayWrapper pa,
            UIntArray indices, double* xmin, double length,
            cOctreeNode* node, int level, double eps):
        cdef double* src_x_ptr = pa.x.data
        cdef double* src_y_ptr = pa.y.data
        cdef double* src_z_ptr = pa.z.data
        cdef double* src_h_ptr = pa.h.data

        cdef double xmin_new[3]
        cdef double hmax_children[8]
        cdef int depth_child = 0
        cdef int depth_max = 0

        cdef int i, j, k
        cdef u_int p, q

        for i from 0<=i<8:
            hmax_children[i] = 0

        cdef cOctreeNode* temp = NULL
        cdef int oct_id

        if (indices.length < self.leaf_max_particles) or (eps > EPS_MAX):
            node.indices = <void*>indices
            Py_XINCREF(<PyObject*>indices)
            node.num_particles = indices.length
            node.is_leaf = True
            return 1

        cdef list new_indices = [UIntArray() for i in range(8)]

        for p from 0<=p<indices.length:
            q = indices.data[p]

            find_cell_id_raw(
                    src_x_ptr[q] - xmin[0],
                    src_y_ptr[q] - xmin[1],
                    src_z_ptr[q] - xmin[2],
                    length/2,
                    &i, &j, &k
                    )

            oct_id = k+2*j+4*i

            (<UIntArray>new_indices[oct_id]).c_append(q)
            hmax_children[oct_id] = fmax(hmax_children[oct_id],
                    self.radius_scale*src_h_ptr[q])

        cdef double length_padded = (length/2)*(1 + 2*eps)

        for i from 0<=i<2:
            for j from 0<=j<2:
                for k from 0<=k<2:

                    xmin_new[0] = xmin[0] + (i - eps)*length/2
                    xmin_new[1] = xmin[1] + (j - eps)*length/2
                    xmin_new[2] = xmin[2] + (k - eps)*length/2

                    oct_id = k+2*j+4*i

                    node.children[oct_id] = self._new_node(xmin_new, length_padded,
                            hmax=hmax_children[oct_id], level=level+1, parent=node)

                    depth_child = self._c_build_tree(pa, <UIntArray>new_indices[oct_id],
                            xmin_new, length_padded, node.children[oct_id], level+1, 2*eps)

                    depth_max = <int>fmax(depth_max, depth_child)

        return 1 + depth_max

    cdef void _plot_tree(self, OctreeNode node, ax):
        node.plot(ax)

        cdef OctreeNode child
        cdef list children = node.get_children()

        for child in children:
            self._plot_tree(child, ax)

    cdef int c_build_tree(self, NNPSParticleArrayWrapper pa_wrapper):

        self._calculate_domain(pa_wrapper)

        cdef int num_particles = pa_wrapper.get_number_of_particles()
        cdef UIntArray indices = UIntArray()
        indices.c_reserve(num_particles)

        cdef int i
        for i from 0<=i<num_particles:
            indices.c_append(i)

        if self.tree != NULL:
            self._delete_tree(self.tree)
        self.tree = self._new_node(self.xmin, self.length,
                hmax=self.radius_scale*self.hmax, level=0)

        self.depth = self._c_build_tree(pa_wrapper, indices, self.tree.xmin,
                self.tree.length, self.tree, 0, self._eps0)

        return self.depth

    cdef void c_get_leaf_cells(self, OctreeNode node, list leaf_cells):
        if node.is_leaf:
            leaf_cells.append(node)

        cdef OctreeNode child
        cdef list children = node.get_children()
        for child in children:
            self.c_get_leaf_cells(child, leaf_cells)

    @cython.cdivision(True)
    cdef cOctreeNode* c_find_point(self, double x, double y, double z):
        cdef cOctreeNode* node = self.tree
        cdef cOctreeNode* prev = self.tree

        cdef int i, j, k, oct_id
        while node != NULL:
            find_cell_id_raw(
                    x - node.xmin[0],
                    y - node.xmin[1],
                    z - node.xmin[2],
                    node.length/2,
                    &i, &j, &k
                    )

            oct_id = k+2*j+4*i
            prev = node
            node = node.children[oct_id]

        return prev

    cpdef int build_tree(self, ParticleArray pa):
        cdef NNPSParticleArrayWrapper pa_wrapper = NNPSParticleArrayWrapper(pa)
        return self.c_build_tree(pa_wrapper)

    cpdef OctreeNode get_root(self):
        cdef OctreeNode py_node = OctreeNode()
        py_node.wrap_node(self.tree)
        return py_node

    cpdef list get_leaf_cells(self):
        cdef OctreeNode root = self.get_root()
        cdef list leaf_cells = []
        self.c_get_leaf_cells(root, leaf_cells)
        return leaf_cells

    cpdef OctreeNode find_point(self, double x, double y, double z):
        cdef cOctreeNode* node = self.c_find_point(x, y, z)
        cdef OctreeNode py_node = OctreeNode()
        py_node.wrap_node(node)
        return py_node

    cpdef plot(self, ax):
        cdef OctreeNode root = self.get_root()
        self._plot_tree(root, ax)

