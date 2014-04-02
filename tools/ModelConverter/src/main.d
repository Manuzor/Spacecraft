import thBase.io;
import thBase.string;
import thBase.container.stack;
import thBase.container.hashmap;
import thBase.container.vector;
import thBase.policies.hashing;
import thBase.scoped;
import thBase.file;
import thBase.chunkfile;
import thBase.format;
import thBase.math;
import thBase.math3d.all;
import thBase.math3d.mats;
import thBase.math3d.vecs;
import thBase.casts;
import thBase.asserthandler;
import assimp.assimp;
import modeltypes;
import core.stdc.stdlib;

rcstring g_workDir;
bool g_debug = false;
bool g_includeMissingTextures = false;

static ~this()
{
  g_workDir = rcstring();
}

struct MaterialTextureInfo
{
  uint id;
  TextureType semantic;
}

void Warning(string fmt, ...)
{
  StdOutPutPolicy put;
  formatDo!StdOutPutPolicy(put, "Warning: ", [], null);
  formatDo(put, fmt, _arguments, _argptr);
  put.put('\r');
  put.put('\n');
  put.flush();
}

void Error(string fmt, ...)
{
  auto dummy = NothingPutPolicy!char();
  size_t needed = formatDo(dummy,fmt,_arguments,_argptr);
  auto result = rcstring(needed);
  auto put = BufferPutPolicy!char(cast(char[])result[]);
  formatDo(put,fmt,_arguments,_argptr);
  throw New!RCException(result);
}

TextureType MapTextureType(aiTextureType type)
{
  switch(type)
  {
    case aiTextureType.NONE:
      return TextureType.UNKNOWN;
    case aiTextureType.DIFFUSE:
      return TextureType.DIFFUSE;
    case aiTextureType.SPECULAR:
      return TextureType.SPECULAR;
    case aiTextureType.EMISSIVE:
      return TextureType.EMISSIVE;
    case aiTextureType.HEIGHT:
      return TextureType.HEIGHT;
    case aiTextureType.NORMALS:
      return TextureType.NORMALS;
    case aiTextureType.LIGHTMAP:
      return TextureType.LIGHTMAP;
    case aiTextureType.REFLECTION:
      return TextureType.REFLECTION;
    default:
      return TextureType.UNKNOWN;
  }
}

short CompressFloat(float f)
{
  if(f < -1.0f || f > 1.0f)
    Error("out of range compression");
  return cast(short)(cast(float)short.max * f);
}

mat4 Convert(ref const(aiMatrix4x4) pData){
  mat4 result;
  with(result){
    f[ 0] = pData.a1; f[ 1] = pData.a2; f[ 2] = pData.a3; f[ 3] = pData.a4;
    f[ 4] = pData.b1; f[ 5] = pData.b2; f[ 6] = pData.b3; f[ 7] = pData.b4;
    f[ 8] = pData.c1; f[ 9] = pData.c2; f[10] = pData.c3; f[11] = pData.c4;
    f[12] = pData.d1; f[13] = pData.d2; f[14] = pData.d3; f[15] = pData.d4;
  }
  result = result.Transpose();
  return result;
}

struct BoneNode
{
  // For generating unique IDs
  static ushort counter = 1;

public:

  // Hierarchy stuff
  BoneNode* parent;
  Vector!(BoneNode*) children;

  // Actual bone data
  ushort id;
  const(char)[] name;
  mat4 offsetMatrix;
  
  this(const(aiBone)* bone)
  {
    id = counter++;
    parent = null;
    children = New!(Vector!(BoneNode*))();
    name = bone.mName.data[0..bone.mName.length];
    offsetMatrix = Convert(bone.mOffsetMatrix);
  }

  ~this()
  {
    Delete(children);
  }
}

void ProgressModel(string path)
{
  try
  {
    const(aiScene)* scene = Assimp.ImportFile(toCString(path), 
                                              aiPostProcessSteps.CalcTangentSpace |
                                              aiPostProcessSteps.Triangulate |
                                              aiPostProcessSteps.JoinIdenticalVertices |
                                              aiPostProcessSteps.FlipUVs);// |
    //aiPostProcessSteps.MakeLeftHanded); // |
    //aiPostProcessSteps.PreTransformVertices );
    if(scene is null){
      Error("Couldn't load model from file '%s'", path);
    }

    scope(exit)
    {
      Assimp.ReleaseImport(cast(aiScene*)scene);
      scene = null;
    }

    rcstring outputFilename = path[0..$-4];
    outputFilename ~= ".thModel";

    auto outFile = scopedRef!Chunkfile(outputFilename, Chunkfile.Operation.Write, g_debug ? Chunkfile.DebugMode.On : Chunkfile.DebugMode.Off);

    outFile.startWriting("thModel", ModelFormatVersion.max);
    scope(exit) outFile.endWriting();

    auto textureFiles = scopedRef!(Hashmap!(const(char)[], uint, StringHashPolicy))(NoArgs());
    auto materialTextures = scopedRef!(Vector!MaterialTextureInfo)(NoArgs());
    auto textures = scopedRef!(Vector!(const(char)[]))(NoArgs());
    auto materialNames = scopedRef!(Vector!(const(char)[]))(NoArgs());
    uint numTextureReferences;

    // Collect Textures
    {
      uint nextTextureId = 0;

      if(scene.mMaterials !is null)
      {

        //collect all textures from all materials
        for(size_t i=0; i<scene.mNumMaterials; i++)
        {
          bool foundMatName = false;
          const(aiMaterial*) mat = scene.mMaterials[i];
          for(int j=0; j < mat.mNumProperties; j++)
          {
            const(aiMaterialProperty*) prop = mat.mProperties[j];
            if(prop.mKey.data[0..prop.mKey.length] == "$tex.file")
            {
              const(char)[] textureFilename = prop.mData[4..prop.mDataLength-1];
              rcstring texturePath;
              if(textureFilename[0..2] == ".\\" || textureFilename[0..2] == "./")
                texturePath = textureFilename[2..$];
              else
                texturePath = textureFilename;
              texturePath = g_workDir ~ texturePath;
              if(textureFilename != "$texture.png")
              {
                if(!g_includeMissingTextures && !thBase.file.exists(texturePath[]))
                {
                  Warning("Couldn't find file '%s' at '%s' ignoring...", textureFilename, texturePath[]);
                }
                else if(MapTextureType(cast(aiTextureType)prop.mSemantic) == TextureType.UNKNOWN)
                {
                  Warning("Texture '%s' has non supported semantic, ignoring...", textureFilename);
                }
                else {
                  numTextureReferences++;
                  if(!textureFiles.exists(textureFilename))
                  {
                    uint index = cast(uint)textures.length;
                    textureFiles[textureFilename] = index;
                    textures ~= textureFilename;
                  }
                }
              }
            }
            else if(prop.mKey.data[0..prop.mKey.length] == "?mat.name") 
            {
              const(char)[] materialName = prop.mData[4..prop.mDataLength-1];
              materialNames ~= materialName;
              foundMatName = true;
            }
          }
          if(!foundMatName)
          {
            Warning("Couldn't find name for material %d using 'default'", i);
            materialNames~= cast(const(char[]))"default";
          }
        }
      }
    }

    auto uniqueBones = composite!( Hashmap!(const(char)[], BoneNode*, StringHashPolicy) )(defaultCtor);
    scope(exit){
      foreach(bone; uniqueBones.values)
      {
        Delete(bone);
      }
    }
    // Collect unique bones
    {
      // Collect all unique bones from all meshes
      for(size_t i=0; i < scene.mNumMeshes; i++)
      {
        const(aiMesh*) aimesh = scene.mMeshes[i];
        for(size_t j = 0; j < aimesh.mNumBones; j++)
        {
          auto bone = aimesh.mBones[j];
          auto key = bone.mName.data[0..bone.mName.length];
          if(!uniqueBones.exists(key))
          {
            uniqueBones[key] = New!(BoneNode)(bone);
          }
        }
      }
    }

    // Build bone hierarchy
    {
      // Define helper functions
      void findBoneRoots(const(aiNode)* sceneNode, Vector!(const(aiNode)*) boneRoots)
      {
        auto nodeName = sceneNode.mName.data[0..sceneNode.mName.length];
        if(uniqueBones.exists(nodeName))
        {
          boneRoots.push_back(sceneNode);
          return;
        }
        foreach(childNode; sceneNode.mChildren[0..sceneNode.mNumChildren])
        {
          findBoneRoots(childNode, boneRoots);
        }
      }
      void buildHierarchy(const(aiNode)* sceneNode, BoneNode* parent)
      {
        foreach(childNode; sceneNode.mChildren[0..sceneNode.mNumChildren])
        {
          auto boneName = childNode.mName.data[0..childNode.mName.length];
          auto bone = uniqueBones[boneName];
          bone.parent = parent;
          parent.children.push_back(bone);
          buildHierarchy(childNode, bone);
        }
      }

      // Begin the actual processing
      auto boneRoots = composite!(Vector!(const(aiNode)*))(defaultCtor);
      findBoneRoots(scene.mRootNode, boneRoots);

      foreach(boneRoot ; boneRoots)
      {
        auto boneName = boneRoot.mName.data[0..boneRoot.mName.length];
        buildHierarchy(boneRoot, uniqueBones[boneName]);
      }
      
    }

    //Size information
    {
      outFile.startWriteChunk("sizeinfo");
      scope(exit) outFile.endWriteChunk();

      outFile.write(cast(uint)textures.length);
      uint texturePathMemory = 0;
      foreach(const(char)[] filename; textures){
        texturePathMemory += filename.length;
      }
      outFile.write(texturePathMemory);

      uint materialNameMemory = 0;
      foreach(const(char)[] materialName; materialNames)
      {
        materialNameMemory += materialName.length;
      }
      outFile.write(materialNameMemory);

      // calc boneNode memory
      {
        uint boneNameMemory = 0;
        uint numChildren = 0;
        foreach(bone; uniqueBones)
        {
          boneNameMemory += bone.name.length;
          numChildren += bone.children.length;
        }
        outFile.write(boneNameMemory);
        outFile.write(int_cast!uint(uniqueBones.count));
        outFile.write(numChildren);
      }

      // calc bone memory of meshes
      {
        uint numBoneInfos = 0;
        for(size_t i=0; i<scene.mNumMeshes; i++)
        {
          const(aiMesh*) aimesh = scene.mMeshes[i];
          numBoneInfos += aimesh.mNumVertices;
        }
        outFile.write(numBoneInfos);
      }

      outFile.write(scene.mNumMaterials);
      outFile.write(scene.mNumMeshes);
      for(size_t i=0; i<scene.mNumMeshes; i++)
      {
        const(aiMesh*) aimesh = scene.mMeshes[i];
        outFile.write(aimesh.mNumVertices);
        uint PerVertexFlags = PerVertexData.Position;
        if(aimesh.mNormals !is null)
          PerVertexFlags |= PerVertexData.Normal;
        if(aimesh.mTangents !is null)
          PerVertexFlags |= PerVertexData.Tangent;
        if(aimesh.mTangents !is null)
          PerVertexFlags |= PerVertexData.Bitangent;
        if(aimesh.mTextureCoords[0] !is null)
          PerVertexFlags |= PerVertexData.TexCoord0;
        if(aimesh.mTextureCoords[1] !is null)
          PerVertexFlags |= PerVertexData.TexCoord1;
        if(aimesh.mTextureCoords[2] !is null)
          PerVertexFlags |= PerVertexData.TexCoord2;
        if(aimesh.mTextureCoords[3] !is null)
          PerVertexFlags |= PerVertexData.TexCoord3;
        outFile.write(PerVertexFlags);
        for(int j=0; j<4; j++)
        {
          if(aimesh.mTextureCoords[j] !is null)
          {
            ubyte numUVComponents = cast(ubyte)aimesh.mNumUVComponents[j];
            if(numUVComponents == 0)
              numUVComponents = 2;
            outFile.write(numUVComponents);
          }
        }
        outFile.write(aimesh.mNumFaces);
      }

      uint numNodes = 0;
      uint numNodeReferences = 0;
      uint numMeshReferences = 0;
      uint nodeNameMemory = 0;

      void nodeSizeHelper(const(aiNode*) node)
      {
        if(node is null)
          return;

        numNodes++;
        numNodeReferences += node.mNumChildren;
        numMeshReferences += node.mNumMeshes;
        nodeNameMemory += node.mName.length;
        foreach(child; node.mChildren[0..node.mNumChildren])
        {
          nodeSizeHelper(child);
        }
      }

      nodeSizeHelper(scene.mRootNode);

      outFile.write(numNodes);
      outFile.write(numNodeReferences);
      outFile.write(nodeNameMemory);
      outFile.write(numMeshReferences);
      outFile.write(numTextureReferences);
    }

    //Write textures
    {
      outFile.startWriteChunk("textures");
      scope(exit){
        size_t size = outFile.endWriteChunk();
        writefln("textures %d kb (%d bytes)", size/1024, size);
      }

      //Write the collected results to the chunkfile
      outFile.write(cast(uint)textures.length);
      foreach(const(char)[] filename; textures)
      {
        outFile.writeArray(filename);
      }
    }

    //Materials
    {
      outFile.startWriteChunk("materials");
      scope(exit) {
        size_t size = outFile.endWriteChunk();
        writefln("materials %d kb", size/1024);
      }

      outFile.write(cast(uint)scene.mNumMaterials);

      if(scene.mMaterials !is null)
      {
        for(size_t i=0; i<scene.mNumMaterials; i++)
        {
          materialTextures.resize(0);
          outFile.startWriteChunk("mat");
          scope(exit) outFile.endWriteChunk();

          const(aiMaterial*) mat = scene.mMaterials[i];
          for(size_t j=0; j<mat.mNumProperties; j++)
          {
            const(aiMaterialProperty*) prop = mat.mProperties[j];
            if(prop.mKey.data[0..prop.mKey.length] == "$tex.file")
            {
              const(char)[] textureFilename = prop.mData[4..prop.mDataLength-1];
              if(textureFiles.exists(textureFilename))
              {
                MaterialTextureInfo info;
                info.id = textureFiles[textureFilename];
                info.semantic = MapTextureType(cast(aiTextureType)prop.mSemantic);
                if(info.semantic != TextureType.UNKNOWN)
                  materialTextures ~= info;
              }
            }
          }

          outFile.writeArray(materialNames[i]);
          outFile.write(cast(uint)materialTextures.length);
          foreach(ref MaterialTextureInfo info; materialTextures)
          {
            outFile.write(info.id);
            outFile.write(info.semantic);
          }
        }
      }
    }

    // Bone hierarchy
    {
      outFile.startWriteChunk("bones");
      scope(exit){
        size_t size = outFile.endWriteChunk();
        writefln("bones (hierarchy) %d kb (%d bytes)", size/1024, size);
      }

      outFile.write(uniqueBones.count);
      for(size_t i = 0; i < uniqueBones.count; ++i)
      {
        foreach(bone; uniqueBones)
        {
          if(bone.id == i + 1) // id of 0 is an invalid id
          {
            outFile.writeArray(bone.name);
            outFile.write(bone.offsetMatrix);
            outFile.write(int_cast!ushort(bone.parent is null ? 0 : bone.parent.id));
            outFile.write(int_cast!uint(bone.children.length));
            foreach(child; bone.children)
            {
              outFile.write(child.id);
            }
          }
        }
      }
    }

    //Meshes
    {
      outFile.startWriteChunk("meshes");
      scope(exit){
        size_t size = outFile.endWriteChunk();
        writefln("meshes %d kb", size/1024);
      }

      outFile.write(cast(uint)scene.mNumMeshes);
      for(size_t i=0; i<scene.mNumMeshes; i++)
      {
        outFile.startWriteChunk("mesh");
        scope(exit) 
        {
          size_t size = outFile.endWriteChunk();
          writefln("mesh %d size %d kb", i, size / 1024);
        }

        const(aiMesh*) aimesh = scene.mMeshes[i];

        //Material index
        outFile.write(cast(uint)aimesh.mMaterialIndex);

        //min, max
        auto minBounds = vec3(float.max, float.max, float.max);
        auto maxBounds = vec3(-float.max, -float.max, -float.max);
        foreach(ref v; (cast(const(vec3*))aimesh.mVertices)[0..aimesh.mNumVertices])
        {
          minBounds = thBase.math3d.all.min(minBounds, v);
          maxBounds = thBase.math3d.all.max(maxBounds, v);
        }
        outFile.write(minBounds.f[]);
        outFile.write(maxBounds.f[]);

        //Num vertices
        writefln("%d vertices", aimesh.mNumVertices);
        outFile.write(cast(uint)aimesh.mNumVertices);

        //vertices
        outFile.startWriteChunk("vertices");
        outFile.write((cast(const(float*))aimesh.mVertices)[0..aimesh.mNumVertices * 3]);
        writefln("mesh %d vertices %d kb", i, outFile.endWriteChunk()/1024);

        if(aimesh.mNormals !is null && (aimesh.mTangents is null || aimesh.mBitangents is null))
        {
          Error("Mesh does have normals but no tangents or bitangents");
        }

        //normals
        if(aimesh.mNormals !is null)
        {
          outFile.startWriteChunk("normals");
          for(size_t j=0; j<aimesh.mNumVertices; j++)
          {
            auto data = (cast(const(float*))(aimesh.mNormals + j))[0..3];
            outFile.write(CompressFloat(data[0]));
            outFile.write(CompressFloat(data[1]));
            outFile.write(CompressFloat(data[2]));
          }
          writefln("mesh %d normals %d kb", i, outFile.endWriteChunk()/1024);
        }

        //tangents
        if(aimesh.mTangents !is null)
        {
          outFile.startWriteChunk("tangents");
          for(size_t j=0; j<aimesh.mNumVertices; j++)
          {
            auto data = (cast(const(float*))(aimesh.mTangents + j))[0..3];
            outFile.write(CompressFloat(data[0]));
            outFile.write(CompressFloat(data[1]));
            outFile.write(CompressFloat(data[2]));
          }
          writefln("mesh %d tangents %d kb", i, outFile.endWriteChunk()/1024);
        }

        //bitangents
        if(aimesh.mBitangents !is null)
        {
          outFile.startWriteChunk("bitangents");
          for(size_t j=0; j<aimesh.mNumVertices; j++)
          {
            auto data = (cast(const(float*))(aimesh.mBitangents + j))[0..3];
            outFile.write(CompressFloat(data[0]));
            outFile.write(CompressFloat(data[1]));
            outFile.write(CompressFloat(data[2]));
          }
          writefln("mesh %d bitangents %d kb", i, outFile.endWriteChunk()/1024);
        }

        //Texture coordinates
        {
          outFile.startWriteChunk("texcoords");
          scope(exit) 
          {
            size_t size = outFile.endWriteChunk();
            writefln("mesh %d texcoords %d kb", i, size/1024);
          }

          ubyte numTexCoords = 0;
          static assert(AI_MAX_NUMBER_OF_TEXTURECOORDS >= 4);
          while(numTexCoords < 4 && aimesh.mTextureCoords[numTexCoords] !is null)
            numTexCoords++;

          outFile.write(numTexCoords);
          for(ubyte j=0; j<numTexCoords; j++)
          {
            ubyte numUVComponents = cast(ubyte)aimesh.mNumUVComponents[j];
            if(numUVComponents == 0)
              numUVComponents = 2;
            outFile.write(numUVComponents);
            if(numUVComponents == 3)
            {
              outFile.write((cast(const(float*))aimesh.mTextureCoords[j])[0..aimesh.mNumVertices*3]);
            }
            else
            {
              for(size_t k=0; k<aimesh.mNumVertices; k++)
              {
                outFile.write((cast(const(float*))&aimesh.mTextureCoords[j][k].x)[0..numUVComponents]);
              }
            }
          }
        }

        struct BoneInfo
        {
          ushort[4] boneIds = [0, 0, 0, 0];
          float[4] boneWeights = [0, 0, 0, 0];
        }

        static assert(BoneInfo.sizeof == ushort.sizeof*4 + float.sizeof*4);

        // Bones
        {
          outFile.startWriteChunk("bones");
          scope(exit) 
          {
            size_t size = outFile.endWriteChunk();
            writefln("boneInfos %d kb", size / 1024);
          }

          //Inversing bone-vertex relations
          // boneInfos -> vertices ==> vertices -> boneInfos

          auto boneInfos = NewArray!BoneInfo(aimesh.mNumVertices);
          scope(exit) Delete(boneInfos);

          auto numBones = NewArray!ubyte(aimesh.mNumVertices);
          scope(exit) Delete(numBones);
          foreach(ushort j, bone; aimesh.mBones[0..aimesh.mNumBones])
          {
            foreach(weight; bone.mWeights[0..bone.mNumWeights])
            {
              auto numBonesOnVertex = numBones[weight.mVertexId];
              if(numBonesOnVertex > 4)
              {
                Error("Vertices that are influenced by more than 4 bones are NOT supported!");
              }

              numBonesOnVertex++;
              numBones[weight.mVertexId] = numBonesOnVertex;
              auto boneIndexOnVertex = numBonesOnVertex - 1;

              boneInfos[weight.mVertexId].boneWeights[boneIndexOnVertex] = weight.mWeight;
              boneInfos[weight.mVertexId].boneIds[boneIndexOnVertex] = uniqueBones[bone.mName.data[0..bone.mName.length]].id;
            }
          }
          outFile.writeArray(boneInfos);
        }

        //Faces
        {
          outFile.startWriteChunk("faces");
          outFile.write(cast(uint)aimesh.mNumFaces);
          if(aimesh.mNumVertices > ushort.max)
          {
            for(size_t j=0; j<aimesh.mNumFaces; j++)
            {
              if(aimesh.mFaces[j].mNumIndices != 3)
                Error("Non triangle face in mesh");
              outFile.write(aimesh.mFaces[j].mIndices[0..3]);
            }
          }
          else
          {
            for(size_t j=0; j<aimesh.mNumFaces; j++)
            {
              if(aimesh.mFaces[j].mNumIndices != 3)
                Error("Non triangle face in mesh");
              outFile.write(cast(ushort)aimesh.mFaces[j].mIndices[0]);
              outFile.write(cast(ushort)aimesh.mFaces[j].mIndices[1]);
              outFile.write(cast(ushort)aimesh.mFaces[j].mIndices[2]);
            }
          }
          writefln("mesh %d faces %d kb", i, outFile.endWriteChunk()/1024);
        }
      }
    }

    //Nodes
    {
      outFile.startWriteChunk("nodes");
      scope(exit) {
        size_t size = outFile.endWriteChunk();
        writefln("nodes %d kb",size/1024);
      }

      auto nodeLookup = scopedRef!(Hashmap!(void*, uint))(NoArgs());
      uint nextNodeId = 0;

      uint countNodes(const(aiNode*) node)
      {
        if(node is null)
          return 0;

        nodeLookup[cast(void*)node] = nextNodeId++; 

        if(node.mNumChildren == 0)
          return 0;

        uint count = node.mNumChildren;
        foreach(child; node.mChildren[0..node.mNumChildren])
        {
          count += countNodes(child);
        }
        return count;
      }

      uint numNodes = countNodes(scene.mRootNode) + 1;
      outFile.write(numNodes);

      void writeNode(const(aiNode*) node)
      {
        if(node is null)
          return;

        outFile.writeArray(node.mName.data[0..node.mName.length]);
        auto transform = Convert(node.mTransformation);
        outFile.write(transform.f[]);
        if(node.mParent is null)
          outFile.write(uint.max);
        else
          outFile.write(nodeLookup[cast(void*)node.mParent]);

        outFile.writeArray(node.mMeshes[0..node.mNumMeshes]);

        outFile.write(node.mNumChildren);
        for(uint i=0; i<node.mNumChildren; i++)
        {
          outFile.write(nodeLookup[cast(void*)node.mChildren[i]]);
        }

        foreach(child; node.mChildren[0..node.mNumChildren])
        {
          writeNode(child);
        }
      }
      writeNode(scene.mRootNode);
    }
  }
  catch(Exception ex)
  {
    writefln("Error progressing model '%s': %s", path, ex.toString()[]);
    Delete(ex);
  }
}

int main(string[] args)
{
  thBase.asserthandler.Init();
  Assimp.Load("assimp.dll","");
  auto models = scopedRef!(Stack!string)(NoArgs());
  for(size_t i=1; i<args.length; i++)
  {
    if(args[i] == "--workdir")
    {
      if(i + 1 > args.length)
      {
        writefln("Error: Missing argument after --workdir");
        return -1;
      }
      g_workDir = args[++i];
      if(g_workDir[g_workDir.length-1] != '\\' && g_workDir[g_workDir.length-1] != '/')
        g_workDir ~= '\\';
    }
    else if(args[i] == "--debug")
    {
      g_debug = true;
    }
    else if(args[i] == "--includeMissingTextures")
    {
      g_includeMissingTextures = true;
    }
    else if(args[i].endsWith(".dae", CaseSensitive.no))
    {
      if(thBase.file.exists(args[i]))
        models.push(args[i]);
      else
      {
        writefln("File: %s does not exist", args[i]);
      }
    }
    else
    {
      writefln("Error: Unkown command line option %s", args[i]);
    }
  }
  if(models.size == 0)
  {
    writefln("No model specified");
    return 1;
  }

  try {
    while(models.size > 0)
    {
      ProgressModel(models.pop());
    }
  }
  catch(Throwable ex)
  {
    writefln("Fatal error: %s", ex.toString()[]);
    Delete(ex);
    return -1;
  }

  system("pause");

  return 0;
}