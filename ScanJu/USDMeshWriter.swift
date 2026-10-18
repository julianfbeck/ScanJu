import Foundation
import simd

// USD Preview Surface with native camera images and face-varying calibrated UVs.
// The companion USDZ uses stored ZIP entries aligned to 64 bytes per OpenUSD.
final class USDMeshWriter {
    private let handle: FileHandle

    init(url: URL, frames: [CameraSample]) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try write("""
        #usda 1.0
        (
            defaultPrim = "ScanJu"
            metersPerUnit = 1
            upAxis = "Y"
        )
        def Xform "ScanJu" {
            def Scope "Materials" {
        """ + "\n")
        try material(name: "unobserved", image: nil)
        for (index, frame) in frames.enumerated() { try material(name: "camera_\(index)", image: frame.image) }
        try write("    }\n")
    }

    private func material(name: String, image: String?) throws {
        let path = "/ScanJu/Materials/\(name)"
        var text = """
                def Material "\(name)" {
                    token outputs:surface.connect = <\(path)/Surface.outputs:surface>
                    def Shader "Surface" {
                        uniform token info:id = "UsdPreviewSurface"
                        float inputs:roughness = 1
                        float inputs:metallic = 0
        """ + "\n"
        if image != nil {
            text += "                color3f inputs:diffuseColor.connect = <\(path)/Texture.outputs:rgb>\n"
        } else {
            text += "                color3f inputs:diffuseColor = (0.48, 0.56, 0.55)\n"
        }
        text += "                token outputs:surface\n            }\n"
        if let image {
            text += """
                        def Shader "UVReader" {
                            uniform token info:id = "UsdPrimvarReader_float2"
                            token inputs:varname = "st"
                            float2 outputs:result
                        }
                        def Shader "Texture" {
                            uniform token info:id = "UsdUVTexture"
                            asset inputs:file = @\(image)@
                            token inputs:sourceColorSpace = "sRGB"
                            float2 inputs:st.connect = <\(path)/UVReader.outputs:result>
                            float3 outputs:rgb
                        }
            """ + "\n"
        }
        text += "        }\n"
        try write(text)
    }

    func append(chunk: MeshChunk, faces: [(SIMD3<UInt32>, [SIMD2<Float>])], name: String, material: Int) throws {
        guard !faces.isEmpty else { return }
        var indices: [UInt32: Int] = [:]
        var vertices: [SIMD3<Float>] = []
        var faceIndices: [Int] = []
        for (face, _) in faces {
            for source in [face.x, face.y, face.z] {
                if indices[source] == nil { indices[source] = vertices.count; vertices.append(chunk.vertices[Int(source)]) }
                faceIndices.append(indices[source]!)
            }
        }
        let materialName = material < 0 ? "unobserved" : "camera_\(material)"
        var text = """
            def Mesh "\(name)" (
                prepend apiSchemas = ["MaterialBindingAPI"]
            ) {
                uniform token subdivisionScheme = "none"
                uniform bool doubleSided = true
                rel material:binding = </ScanJu/Materials/\(materialName)>
        """ + "\n"
        text += "        point3f[] points = [" + vertices.map { "(\($0.x),\($0.y),\($0.z))" }.joined(separator: ",") + "]\n"
        text += "        int[] faceVertexCounts = [" + Array(repeating: "3", count: faces.count).joined(separator: ",") + "]\n"
        text += "        int[] faceVertexIndices = [" + faceIndices.map(String.init).joined(separator: ",") + "]\n"
        if material >= 0 {
            text += "        texCoord2f[] primvars:st = [" + faces.flatMap { $0.1 }.map { "(\($0.x),\($0.y))" }.joined(separator: ",") + "] (interpolation = \"faceVarying\")\n"
        }
        text += "    }\n"
        try write(text)
    }

    func finish() throws { try write("}\n"); try handle.synchronize() }
    func close() { try? handle.close() }
    private func write(_ text: String) throws { try handle.write(contentsOf: Data(text.utf8)) }
}
