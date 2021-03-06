module game.collision;

import thBase.math3d.all;
import base.renderer;
import thBase.string;
import core.refcounted;
import core.allocator;
import thBase.scoped;
import base.modelloader;
import thBase.enumbitfield;
import thBase.math;
import thBase.logging;

class CollisionHull {
private
	Triangle[] m_Faces;
	
public:
  vec3 minBounds, maxBounds;
  float boundingRadius;

	/**
	 * Builds a new collison hull from the model in pFilename.
	 */
	this(rcstring pFilename){
		Load(pFilename);
	}

  ~this()
  {
    Delete(m_Faces);
  }
	
	/**
	 * Loads a collision mesh from a model file, the model file may only contain one single mesh
	 * Params:
	 *  pFilename = the file to load
	 */
	void Load(rcstring pFilename){
		auto loader = scopedRef!(ModelLoader, ThreadLocalStackAllocator)(AllocatorNew!ModelLoader(ThreadLocalStackAllocator.globalInstance));
    loader.LoadFile(pFilename, EnumBitfield!(ModelLoader.Load)(ModelLoader.Load.Meshes, ModelLoader.Load.Nodes));
		
		if(loader.modelData.meshes.length > 1){
			throw New!RCException(format("The collision mesh '%s' does contain more that 1 mesh", pFilename[]));
		}
		
		auto mesh = loader.modelData.meshes[0];
    if(m_Faces)
    {
      Delete(m_Faces);
    }
		m_Faces = NewArray!Triangle(mesh.faces.length);
    auto vertices = AllocatorNewArray!vec3(ThreadLocalStackAllocator.globalInstance, mesh.vertices.length);
    scope(exit) AllocatorDelete(ThreadLocalStackAllocator.globalInstance, vertices);
    
    const(ModelLoader.NodeDrawData*) findLeaf(const(ModelLoader.NodeDrawData*) node)
    {
      if(node.meshes.length > 0)
      {
        return node;
      }
      foreach(child; node.children)
      {
        auto result = findLeaf(child);
        if(result !is null)
        {
          return result;
        }
      }
      return null;
    }

    const(ModelLoader.NodeDrawData)* curNode = findLeaf(loader.modelData.rootNode);
    assert(curNode !is null, "no node with mesh found");
    mat4 transform = loader.modelData.rootNode.transform;
    while(curNode !is null && curNode != loader.modelData.rootNode)
    {
      transform = curNode.transform * transform;
      curNode = curNode.data.parent;
    }

    minBounds = vec3(float.max, float.max, float.max);
    maxBounds = vec3(-float.max, -float.max, -float.max);
    boundingRadius = 0.0f;

    foreach(size_t i, ref vertex; vertices)
    {
      vertex = transform * mesh.vertices[i];
      minBounds = minimum(minBounds, vertex);
      maxBounds = maximum(maxBounds, vertex);
      boundingRadius = max(boundingRadius, vertex.length);
    }
    logInfo("%s => minBounds %s, maxBounds %s", pFilename[], minBounds.f[], maxBounds.f[]);

		
		foreach(size_t i,ref face;m_Faces)
    {			
			face.v0 = vertices[mesh.faces[i].indices[0]];
      face.v1 = vertices[mesh.faces[i].indices[1]];
      face.v2 = vertices[mesh.faces[i].indices[2]];
      face.plane = Plane(face.v0, face.v1, face.v2);
		}
	}

  /**
   * tests if two collision hulls intersect
   * Params:
   *  other = the other collision hull to test with
   *  otherSpaceToThisSpace = a transformation that will transform the vertices of the other collision hull into the space of this collision hull
   * Returns:
   *  true if the two intersect, false otherwise
   */
  bool intersectsFast(const(CollisionHull) other, mat4 otherSpaceToThisSpace) const
  {
    Ray dummy;
    foreach(ref f1; other.m_Faces)
    {
      Triangle rhTri = f1.transform(otherSpaceToThisSpace);
      foreach(ref lhTri; m_Faces)
      {
        if(rhTri.intersects(lhTri, dummy))
          return true;
      }
    }

    return false;
  }

  /**
  * tests if two collision hulls intersect
  * Params:
  *  other = the other collision hull to test with
  *  otherSpaceToThisSpace = a transformation that will transform the vertices of the other collision hull into the space of this collision hull
  *  results = a preallocated array of which will be filled with the results
  * Returns:
  *  the number of intersections found
  */
  size_t getIntersections(const(CollisionHull) other, mat4 otherSpaceToThisSpace, scope Ray[] results) const
  {
    Ray dummy;
    size_t i=0;
    foreach(ref f1; other.m_Faces)
    {
      Triangle rhTri = f1.transform(otherSpaceToThisSpace);
      foreach(ref lhTri; m_Faces)
      {
        if(i >= results.length)
          return i;
        if(rhTri.intersects(lhTri, results[i]))
        {
          i++;
        }
      }
    }

    return i;
  }
	
	/**
	 * Tests for a intersection with a already correctly transformed ray and this collision hull
	 * Params:
	 *  ray = the ray to test with
	 *  lhTrans = the transformation to apply to this collision hull
	 *  rayPos = the position on the ray where it did intersect (out = result)
   *  normal = the normal at the intersection
	 */
	bool intersects(Ray ray,mat4 lhTrans,ref float rayPos, ref vec3 normal) const {
		bool result = false;
		rayPos = float.max;
		foreach(ref f; m_Faces){
			Triangle lhTri = f.transform(lhTrans);
			float pos = -1.0f;
			if( lhTri.intersects(ray,pos) ){
				if(pos < rayPos && pos >= 0.0f){
          result = true;
					rayPos = pos;
					normal = lhTri.plane.normal;
				}
			}
		}
		return result;
	}
	
	/**
	 * Draws a transformed version of the collision mesh
	 * Pararms:
	 *  position = position of the collision mesh
   *  rotation = rotation of the collision mesh
	 *  renderer = the renderer to use for drawing
	 *  color = the color to use (optional)
	 */
	void debugDraw(Position position, Quaternion rotation, shared(IRenderer) renderer, vec4 color = vec4(1.0f,1.0f,1.0f,1.0f)) const {
		mat4 transformation = rotation.toMat4();
    foreach(ref f;m_Faces){
			Triangle curFace = f.transform(transformation);
			
			renderer.drawLine(position + curFace.v0,position + curFace.v1,color);
			renderer.drawLine(position + curFace.v0,position + curFace.v2,color);
			renderer.drawLine(position + curFace.v1,position + curFace.v2,color);
		}
	}

  /**
  * Draws a transformed version of the collision mesh
  * Pararms:
  *  transformation = the transformation to use
  *  renderer = the renderer to use for drawing
  *  color = the color to use (optional)
  */
  void debugDraw(mat4 transform, shared(IRenderer) renderer, vec4 color  = vec4(1.0f,1.0f,1.0f,1.0f)) const 
  {
    foreach(ref f;m_Faces){
			Triangle curFace = f.transform(transform);
      Position v0 = Position(curFace.v0);
      Position v1 = Position(curFace.v1);
      Position v2 = Position(curFace.v2);

			renderer.drawLine(v0, v1, color);
			renderer.drawLine(v0, v2, color);
			renderer.drawLine(v1, v2, color);
		}
  }
	
	/**
	 * Computes the bounding box for this collision mesh
	 * Returns: A axis aligned bounding box
	 */
	AlignedBox boundingBox(){
		vec3 min = vec3(float.max);
		vec3 max = vec3(-float.max);
		foreach(ref f;m_Faces){
			auto v = f.v0;
			if(v.x < min.x) min.x = v.x;
			if(v.y < min.y) min.y = v.y;
			if(v.z < min.z) min.z = v.z;
				
			if(v.x > max.x) max.x = v.x;
			if(v.y > max.y) max.y = v.y;
			if(v.z > max.z) max.z = v.z;

			v = f.v1;
			if(v.x < min.x) min.x = v.x;
			if(v.y < min.y) min.y = v.y;
			if(v.z < min.z) min.z = v.z;

			if(v.x > max.x) max.x = v.x;
			if(v.y > max.y) max.y = v.y;
			if(v.z > max.z) max.z = v.z;

			v = f.v2;
			if(v.x < min.x) min.x = v.x;
			if(v.y < min.y) min.y = v.y;
			if(v.z < min.z) min.z = v.z;

			if(v.x > max.x) max.x = v.x;
			if(v.y > max.y) max.y = v.y;
			if(v.z > max.z) max.z = v.z;
		}
		return AlignedBox(min,max);
	}
}
