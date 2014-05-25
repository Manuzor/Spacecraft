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
import core.stdc.stdio;

rcstring g_workDir;
bool g_debug = false;
bool g_log = false;
RawFile g_logFile;
bool g_includeMissingTextures = false;
bool g_flipUVs = true;

static ~this()
{
  g_workDir = rcstring();
}

struct MaterialTextureInfo
{
  uint id;
  TextureType semantic;
}

void showHelp()
{
  writefln("Converts model files to the thModel format using Assimp 3."
           "Available options:\n"
           "  --workdir                  Sets the working dir.\n"
           "  --debug \n"
           "  --includeMissingTextures   Will not ignore referenced texture files that are not present on the disc.\n"
           "  --noPause                  Does not pause at the end of the conversion process.\n"
           "  --log                      Does some minimal logging to a file called 'ModelConverterD.log'.\n"
           "  --noUVFlip                 Does NOT flip UV coordinates, which is usually required for D3D.\n");
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

struct NodeInfo
{
  uint id;
  const(aiNode)* node;
}

struct BoneNode
{
  __gshared ushort counter = 0;

  ushort id;
  NodeInfo node;
  mat4 offsetMatrix;

  this(const(aiBone)* bone, NodeInfo node)
  {
    id = counter++;
    this.node = node;
    offsetMatrix = Convert(bone.mOffsetMatrix);
  }
}

void ProgressModel(string path)
{
  try
  {
    auto importOptions = aiPostProcessSteps.CalcTangentSpace
                       | aiPostProcessSteps.Triangulate
                       | aiPostProcessSteps.JoinIdenticalVertices;
                     //| aiPostProcessSteps.MakeLeftHanded;
                     //| aiPostProcessSteps.PreTransformVertices;
    if(g_flipUVs)
    {
      importOptions |= aiPostProcessSteps.FlipUVs;
    }
    const(aiScene)* scene = Assimp.ImportFile(toCString(path), importOptions);
    if(scene is null){
      Error("Couldn't load model from file '%s'", path);
    }

    if(g_log)
      g_logFile.open("ModelConverterD.log", "w");

    scope(exit)
    {
      if(g_log)
      {
        g_logFile.flush();
        g_logFile.close();
      }

      Assimp.ReleaseImport(cast(aiScene*)scene);
      scene = null;
    }

    rcstring outputFilename = path[0..$-4];
    outputFilename ~= ".thModel";

    auto outFile = scopedRef!Chunkfile(outputFilename, Chunkfile.Operation.Write, g_debug ? Chunkfile.DebugMode.On : Chunkfile.DebugMode.Off);

    outFile.startWriting("thModel", ModelFormatVersion.max);
    scope(exit) outFile.endWriting();

    auto textureFiles = scopedRef!(Hashmap!(const(char)[], uint, StringHashPolicy))(defaultCtor);
    auto materialTextures = scopedRef!(Vector!MaterialTextureInfo)(defaultCtor);
    auto textures = scopedRef!(Vector!(const(char)[]))(defaultCtor);
    auto materialNames = scopedRef!(Vector!(const(char)[]))(defaultCtor);
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

    auto uniqueNodes = composite!( Hashmap!(const(char)[], NodeInfo, StringHashPolicy) )(defaultCtor);

    // Collect NodeInfos
    {
      uint id = 0;
      void collectNodes(const(aiNode)* node)
      {
        auto name = node.mName.data[0..node.mName.length];
        if(!uniqueNodes.exists(name))
        {
          if(g_log) fprintf(g_logFile.m_Handle, "  %.*s\n", name.length, name.ptr);
          uniqueNodes[name] = NodeInfo(id++, node);
        }
        foreach(child ; node.mChildren[0..node.mNumChildren])
        {
          collectNodes(child);
        }
      }
      if(g_log) fprintf(g_logFile.m_Handle, "Nodes:\n");
      collectNodes(scene.mRootNode);
      if(g_log) g_logFile.flush();
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
      if(g_log) fprintf(g_logFile.m_Handle, "Bones:\n");
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
            if(g_log) fprintf(g_logFile.m_Handle, "  %.*s\n", key.length, key.ptr);
            NodeInfo nodeInfo;
            if(!uniqueNodes.tryGet(key, nodeInfo))
            {
              Error("The bone name '%s' was not found as a node!", key);
            }
            uniqueBones[key] = New!(BoneNode)(bone, nodeInfo);
          }
        }
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

      // write boneNode memory
      {
        outFile.write(int_cast!uint(uniqueBones.count));
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

    // write bones
    {
      outFile.startWriteChunk("bones");
      scope(exit){
        size_t size = outFile.endWriteChunk();
        writefln("bones %d kb (%d bytes)", size/1024, size);
      }

      outFile.write(uniqueBones.count);
      for(size_t i = 0; i < uniqueBones.count; ++i)
      {
        foreach(bone; uniqueBones)
        {
          if(bone.id == i)
          {
            outFile.write(bone.offsetMatrix);
            outFile.write(bone.node.id);
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

    // Write Nodes
    {
      outFile.startWriteChunk("nodes");
      scope(exit) {
        size_t size = outFile.endWriteChunk();
        writefln("nodes %d kb",size/1024);
      }

      auto nodeLookup = scopedRef!(Hashmap!(void*, uint))(defaultCtor);
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
  // Pause before exiting by default. Gets set later to false, if --nopause is supplied.
  bool pauseBeforeExiting = true;

  scope(exit){ if(pauseBeforeExiting) system("pause"); }

  thBase.asserthandler.Init();
  Assimp.Load("assimp.dll","");
  auto models = scopedRef!(Stack!string)(defaultCtor);
  for(size_t i=1; i<args.length; i++)
  {
    if(args[i] == "-h" || args[i] == "--help")
    {
      showHelp();
      return 42;
    }

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
    else if(args[i] == "--noPause")
    {
      pauseBeforeExiting = false;
    }
    else if(args[i] == "--log")
    {
      g_log = true;
    }
    else if(args[i] == "--noUVFlip")
    {
      g_log = true;
    }
    else if(thBase.file.exists(args[i]))
    {
      models.push(args[i]);
    }
    else
    {
      if(args[i].startsWith("--"))
      {
        writefln("Error: Unkown command line option %s.", args[i]);
        return 2;
      }

      writefln("Error: File does not exist: %s.", args[i]);
      return 3;
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

  return 0;
}