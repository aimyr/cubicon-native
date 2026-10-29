import AppKit
import SceneKit
import UniformTypeIdentifiers

// This is a native front end. The slicer is an independently compiled Mach-O
// executable; no Windows binary or compatibility layer is invoked here.

struct V3 {
    var x: Double; var y: Double; var z: Double
    static let zero = V3(x: 0, y: 0, z: 0)
    static func +(a: V3, b: V3) -> V3 { V3(x: a.x+b.x, y: a.y+b.y, z: a.z+b.z) }
    static func -(a: V3, b: V3) -> V3 { V3(x: a.x-b.x, y: a.y-b.y, z: a.z-b.z) }
    func scene() -> SCNVector3 { SCNVector3(x, z, -y) }
    func cross(_ b: V3) -> V3 { V3(x: y*b.z-z*b.y, y: z*b.x-x*b.z, z: x*b.y-y*b.x) }
    func unit() -> V3 { let n = sqrt(x*x+y*y+z*z); return n > 1e-12 ? V3(x:x/n,y:y/n,z:z/n) : .zero }
}

struct Bounds {
    var min: V3; var max: V3
    var size: V3 { max-min }
    var center: V3 { V3(x:(min.x+max.x)/2,y:(min.y+max.y)/2,z:(min.z+max.z)/2) }
    init(_ points: [V3]) {
        min = points.first ?? .zero; max = min
        for p in points { min.x = Swift.min(min.x,p.x); min.y = Swift.min(min.y,p.y); min.z = Swift.min(min.z,p.z); max.x = Swift.max(max.x,p.x); max.y = Swift.max(max.y,p.y); max.z = Swift.max(max.z,p.z) }
    }
    mutating func include(_ p:V3) { min.x=Swift.min(min.x,p.x); min.y=Swift.min(min.y,p.y); min.z=Swift.min(min.z,p.z); max.x=Swift.max(max.x,p.x); max.y=Swift.max(max.y,p.y); max.z=Swift.max(max.z,p.z) }
}

struct Mesh {
    var vertices: [V3]
    var name: String
    var triangleCount: Int { vertices.count/3 }
    var bounds: Bounds { Bounds(vertices) }
}

struct ModelTransform {
    var position = V3.zero
    var rotation = V3.zero
    var scale = V3(x: 1,y: 1,z: 1)
    func apply(_ p: V3) -> V3 {
        var v = V3(x:p.x*scale.x,y:p.y*scale.y,z:p.z*scale.z)
        let a = rotation.x * .pi/180, b = rotation.y * .pi/180, c = rotation.z * .pi/180
        v = V3(x:v.x,y:v.y*cos(a)-v.z*sin(a),z:v.y*sin(a)+v.z*cos(a))
        v = V3(x:v.x*cos(b)+v.z*sin(b),y:v.y,z:-v.x*sin(b)+v.z*cos(b))
        v = V3(x:v.x*cos(c)-v.y*sin(c),y:v.x*sin(c)+v.y*cos(c),z:v.z)
        return v + position
    }
}

struct AppError: LocalizedError { let message: String; var errorDescription: String? { message } }

enum MeshIO {
    static let maxTriangles = 2_000_000
    static func read(_ url: URL) throws -> Mesh {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) <= 128*1024*1024 else { throw AppError(message:"This model exceeds the 128 MB import limit.") }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let vertices: [V3]
        if url.pathExtension.lowercased() == "obj" { vertices = try readOBJ(data) }
        else { vertices = try readSTL(data) }
        guard !vertices.isEmpty, vertices.count%3 == 0, vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { throw AppError(message:"The model has no valid triangles or contains invalid coordinates.") }
        return Mesh(vertices:vertices,name:url.lastPathComponent)
    }
    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset+1])<<8 | UInt32(data[offset+2])<<16 | UInt32(data[offset+3])<<24
    }
    private static func f32(_ data: Data, _ offset: Int) -> Double { Double(Float(bitPattern:u32(data,offset))) }
    private static func readSTL(_ data: Data) throws -> [V3] {
        if data.count >= 84 {
            let count = Int(u32(data,80))
            if count > 0, count <= maxTriangles, 84+count*50 <= data.count {
                var vertices: [V3] = []; vertices.reserveCapacity(count*3)
                for i in 0..<count { let base = 84+i*50+12; for j in 0..<3 { let p = base+j*12; vertices.append(V3(x:f32(data,p),y:f32(data,p+4),z:f32(data,p+8))) } }
                return vertices
            }
        }
        guard let text = String(data:data,encoding:.utf8) else { throw AppError(message:"The STL is malformed or uses an unsupported encoding.") }
        var vertices: [V3] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.first?.lowercased() == "vertex", fields.count >= 4, let x = Double(fields[1]), let y = Double(fields[2]), let z = Double(fields[3]) {
                vertices.append(V3(x:x,y:y,z:z))
                if vertices.count > maxTriangles*3 { throw AppError(message:"The model has too many triangles.") }
            }
        }
        return vertices
    }
    private static func readOBJ(_ data: Data) throws -> [V3] {
        guard let text = String(data:data,encoding:.utf8) else { throw AppError(message:"The OBJ is not a UTF-8 text file.") }
        var points: [V3] = [], result: [V3] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line=rawLine.split(separator:"#",maxSplits:1).first ?? ""
            let f = line.split(whereSeparator: \.isWhitespace)
            if f.first == "v", f.count >= 4, let x=Double(f[1]),let y=Double(f[2]),let z=Double(f[3]) { points.append(V3(x:x,y:y,z:z)) }
            if f.first == "f", f.count >= 4 {
                var polygon: [V3] = []
                for entry in f.dropFirst() {
                    guard let token=entry.split(separator:"/",omittingEmptySubsequences:false).first,let index=Int(token) else { throw AppError(message:"The OBJ contains an invalid face index.") }
                    let i = index > 0 ? index-1 : points.count+index
                    guard points.indices.contains(i) else { throw AppError(message:"An OBJ face refers to a missing vertex.") }
                    polygon.append(points[i])
                }
                for i in 1..<(polygon.count-1) { result.append(contentsOf:[polygon[0],polygon[i],polygon[i+1]]) }
                if result.count > maxTriangles*3 { throw AppError(message:"The model has too many triangles.") }
            }
        }
        return result
    }
    static func writeBinarySTL(vertices: [V3], to url: URL) throws {
        var data = Data(repeating:0,count:80)
        let label = Data("Cubicon Native transformed model".utf8)
        data.replaceSubrange(0..<label.count,with:label)
        func appendU32(_ value: UInt32) { var v=value.littleEndian; withUnsafeBytes(of:&v) { data.append(contentsOf:$0) } }
        func appendFloat(_ value: Double) { appendU32(Float(value).bitPattern) }
        appendU32(UInt32(vertices.count/3))
        for i in stride(from:0,to:vertices.count,by:3) {
            let n=(vertices[i+1]-vertices[i]).cross(vertices[i+2]-vertices[i]).unit()
            [n,vertices[i],vertices[i+1],vertices[i+2]].forEach { appendFloat($0.x); appendFloat($0.y); appendFloat($0.z) }
            data.append(0); data.append(0)
        }
        try data.write(to:url,options:.atomic)
    }
}

struct PrinterProfile: Decodable {
    let id: String; let name: String
    let bedWidth: Double; let bedDepth: Double; let bedHeight: Double; let nozzleDiameter: Double
    let settings: [String:String]
    let startGcode: String?; let endGcode: String?; let sourceFiles: [String]?
    let defaultMaterialID: String?; let materialIDs: [String]?
    let materialSettings: [String:[String:String]]?; let expressions: [String:String]?
    var family: String { (id.lowercased().contains("a15") || name.lowercased().contains("a15")) ? "Style Plus A15" : "Single Plus" }
}
struct MaterialPreset: Decodable { let id: String; let name: String; let settings: [String:String]; let printerIDs: [String]? }
struct ProfileDocument: Decodable { let profiles: [PrinterProfile]; let materials: [MaterialPreset]? }

struct Toolpath {
    var layers: [[(V3,V3)]]
    var layerNumbers: [Int]
    var totalMoves: Int
    var extrusionBounds: Bounds?
    var extruderNetMM:Double
    var modelLayerCount:Int { layerNumbers.filter { $0 >= 0 }.count }
    var raftLayerCount:Int { layerNumbers.filter { $0 < 0 }.count }
    static func parse(_ text: String) -> Toolpath {
        var layers: [[(V3,V3)]] = [[]], numbers=[0], p=V3.zero, e=0.0, relativeE=false, absoluteXYZ=true, moves=0, storedMoves=0, hasLayerComments=false
        var extrusionBounds:Bounds?,extruderNetMM=0.0
        var layerZ = 0.0
        for raw in text.split(whereSeparator:\.isNewline) {
            let line=String(raw)
            if line.hasPrefix(";LAYER:") { let number=Int(line.dropFirst(7).trimmingCharacters(in:.whitespaces)) ?? 0; hasLayerComments=true; if !layers[layers.count-1].isEmpty { layers.append([]); numbers.append(number) } else { numbers[numbers.count-1]=number }; continue }
            let code=line.split(separator:";",maxSplits:1).first ?? ""
            let fields=code.split(whereSeparator:\.isWhitespace)
            guard let command=fields.first else { continue }
            if command=="M82" { relativeE=false }; if command=="M83" { relativeE=true }
            if command=="G90" { absoluteXYZ=true }; if command=="G91" { absoluteXYZ=false }
            var values: [Character:Double]=[:]
            for f in fields.dropFirst() { if let letter=f.first,let value=Double(f.dropFirst()) { values[letter]=value } }
            if command=="G92" { if let value=values["E"] { e=value }; continue }
            guard command=="G0" || command=="G1" else { continue }
            var next=p
            if let x=values["X"] { next.x=absoluteXYZ ? x:p.x+x }; if let y=values["Y"] { next.y=absoluteXYZ ? y:p.y+y }; if let z=values["Z"] { next.z=absoluteXYZ ? z:p.z+z }
            if let newE=values["E"] {
                let extrusion=relativeE ? newE:newE-e
                extruderNetMM+=extrusion
                if extrusion > 0.000001, (next-p).x != 0 || (next-p).y != 0 {
                    // A fallback for engines that omit ;LAYER comments.
                    if !hasLayerComments,next.z > layerZ+0.01,!layers[layers.count-1].isEmpty { layers.append([]); numbers.append(numbers.last!+1) }
                    layerZ=next.z
                    if extrusionBounds == nil { extrusionBounds=Bounds([p,next]) } else { extrusionBounds?.include(p); extrusionBounds?.include(next) }
                    if storedMoves < 400_000 { layers[layers.count-1].append((p,next)); storedMoves+=1 }
                    moves+=1
                }
                e=relativeE ? e+newE:newE
            }
            p=next
        }
        let retained=layers.indices.filter { !layers[$0].isEmpty }
        return Toolpath(layers:retained.map { layers[$0] },layerNumbers:retained.map { numbers[$0] },totalMoves:moves,extrusionBounds:extrusionBounds,extruderNetMM:extruderNetMM)
    }
}

final class SliceService {
    private var process: Process?
    private var cancelled=false
    func cancel() { cancelled=true; process?.terminate() }
    func run(resources: URL, model: URL, output: URL, settings: [String:String], log: @escaping (String)->Void, completion: @escaping (Result<String,Error>)->Void) {
        let engine=resources.appendingPathComponent("Engine/CubiEngine")
        guard FileManager.default.isExecutableFile(atPath:engine.path) else { completion(.failure(AppError(message:"The native slicing engine is missing from this application. Rebuild the app with its ARM64 engine."))); return }
        let base=resources.appendingPathComponent("Base.def.json")
        guard FileManager.default.fileExists(atPath:base.path) else { completion(.failure(AppError(message:"The engine's base settings are missing from this application."))); return }
        cancelled=false
        let task=Process(), pipe=Pipe()
        task.executableURL=engine; task.currentDirectoryURL=resources
        var args=["slice","-p","-j",base.path]
        for key in settings.keys.sorted() { args += ["-s","\(key)=\(settings[key]!)"] }
        args += ["-e0","-s","extruder_nr=0","-l",model.path,"-o",output.path]
        task.arguments=args
        var environment=ProcessInfo.processInfo.environment
        environment["CURA_ENGINE_SEARCH_PATH"]=resources.path
        task.environment=environment; task.standardOutput=pipe; task.standardError=pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in let data=handle.availableData; if !data.isEmpty,let value=String(data:data,encoding:.utf8) { DispatchQueue.main.async { log(value) } } }
        process=task
        task.terminationHandler = { [weak self] task in
            pipe.fileHandleForReading.readabilityHandler=nil
            let rest=pipe.fileHandleForReading.readDataToEndOfFile()
            let result: Result<String,Error>
            if self?.cancelled == true { result = .failure(AppError(message:"Slicing cancelled.")) }
            else if task.terminationStatus != 0 { result = .failure(AppError(message:"The native engine stopped with exit \(task.terminationStatus). The engine log below contains the details.")) }
            else if let text=try? String(contentsOf:output,encoding:.utf8),
                    text.range(of:"(?m)^;LAYER:0\\s*$",options:.regularExpression) != nil,
                    text.range(of:"(?m)^;LAYER_COUNT:[1-9][0-9]*\\s*$",options:.regularExpression) != nil,
                    text.range(of:"(?m)^M904(?:[ ;].*)?$",options:.regularExpression) != nil { result = .success(text) }
            else { result = .failure(AppError(message:"The engine exited without generating a complete G-code file.")) }
            DispatchQueue.main.async { if let text=String(data:rest,encoding:.utf8),!text.isEmpty { log(text) }; self?.process=nil; completion(result) }
        }
        do { try task.run() } catch { pipe.fileHandleForReading.readabilityHandler=nil; process=nil; completion(.failure(error)) }
    }
}

@main
final class NativeApp: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate {
    private var window: NSWindow!
    private lazy var sceneView=SCNView()
    private let scene=SCNScene(), bedRoot=SCNNode(), modelRoot=SCNNode(), pathRoot=SCNNode()
    private let camera=SCNNode()
    private var profiles: [PrinterProfile]=[], filteredProfiles: [PrinterProfile]=[], materials: [MaterialPreset]=[]
    private var mesh: Mesh?, transform=ModelTransform(), modelURL: URL?, pendingURL: URL?
    private var transformIsValid=true
    private var gcode: String?, toolpath: Toolpath?, unsavedGcode=false
    private let slicer=SliceService()
    private var busy=false
    private let printerPopup=NSPopUpButton(), profilePopup=NSPopUpButton(), materialPopup=NSPopUpButton()
    private var layerField=NSTextField(string:"0.2"), firstLayerField=NSTextField(string:"0.2"), infillField=NSTextField(string:"20"), nozzleField=NSTextField(string:"210"), bedField=NSTextField(string:"60"), speedField=NSTextField(string:"50")
    private let supports=NSButton(checkboxWithTitle:"Generate supports",target:nil,action:nil)
    private var transformFields: [NSTextField]=[]
    private let modelLabel=NSTextField(wrappingLabelWithString:"Open an STL or OBJ model to begin."), dimensionsLabel=NSTextField(wrappingLabelWithString:""), status=NSTextField(labelWithString:"Ready"), progress=NSProgressIndicator()
    private let logView=NSTextView()
    private var openButton: NSButton!, sliceButton: NSButton!, saveButton: NSButton!, cancelButton: NSButton!
    private let previewMode=NSSegmentedControl(labels:["Model","Toolpath"],trackingMode:.selectOne,target:nil,action:nil)
    private let layerSlider=NSSlider(value:0,minValue:0,maxValue:1,target:nil,action:nil), layerLabel=NSTextField(labelWithString:"No toolpath")
    private var temporaryDirectory: URL?
    private var inspector: NSStackView!
    private var resources: URL { Bundle.main.resourceURL! }
    private var profile: PrinterProfile? { filteredProfiles.indices.contains(profilePopup.indexOfSelectedItem) ? filteredProfiles[profilePopup.indexOfSelectedItem]:nil }

    private static func nozzleOffset(_ settings:[String:String])->V3 {
        guard settings["machine_use_extruder_offset_to_offset_coords"]=="true" else { return .zero }
        return V3(x:Double(settings["machine_nozzle_offset_x"] ?? "0") ?? 0,y:Double(settings["machine_nozzle_offset_y"] ?? "0") ?? 0,z:0)
    }
    private static func logicalBounds(_ path:Toolpath,settings:[String:String])->Bounds? {
        guard let b=path.extrusionBounds else { return nil }
        let offset=nozzleOffset(settings)
        return Bounds([b.min+offset,b.max+offset])
    }
    private static func validateToolpath(_ path:Toolpath,profile:PrinterProfile,settings:[String:String]) throws {
        guard path.totalMoves>0,let b=logicalBounds(path,settings:settings),[b.min.x,b.min.y,b.min.z,b.max.x,b.max.y,b.max.z].allSatisfy(\.isFinite) else { throw AppError(message:"The engine generated no finite extrusion paths.") }
        let centerIsZero=settings["machine_center_is_zero"]=="true",x0=centerIsZero ? -profile.bedWidth/2:0,y0=centerIsZero ? -profile.bedDepth/2:0
        guard b.min.x>=x0-0.25,b.max.x<=x0+profile.bedWidth+0.25,b.min.y>=y0-0.25,b.max.y<=y0+profile.bedDepth+0.25,b.min.z >= -0.05,b.max.z<=profile.bedHeight+0.05 else { throw AppError(message:"The generated extrusion paths exceed the selected printer's build volume. Reduce the model size or adjust its placement.") }
    }
    private static func normalizeGcodeHeader(_ text:String,path:Toolpath,settings:[String:String])->String {
        guard let bounds=logicalBounds(path,settings:settings) else { return text }
        var result=text
        for (key,value) in [("MINX",bounds.min.x),("MINY",bounds.min.y),("MINZ",bounds.min.z),("MAXX",bounds.max.x),("MAXY",bounds.max.y),("MAXZ",bounds.max.z)] {
            guard let expression=try? NSRegularExpression(pattern:"(?m)^;\(key):[^\\r\\n]*") else { continue }
            result=expression.stringByReplacingMatches(in:result,range:NSRange(result.startIndex...,in:result),withTemplate:String(format:";\(key):%.3f",value))
        }
        // The standalone engine's initial TIME comment is a placeholder. Its
        // final TIME_ELAPSED contains the completed motion planner's estimate.
        if let elapsed=try? NSRegularExpression(pattern:"(?m)^;TIME_ELAPSED:([0-9.]+)"),
           let last=elapsed.matches(in:text,range:NSRange(text.startIndex...,in:text)).last,
           let range=Range(last.range(at:1),in:text),let seconds=Double(text[range]),seconds.isFinite,seconds>=0,
           let header=try? NSRegularExpression(pattern:"(?m)^;TIME:[^\\r\\n]*") {
            result=header.stringByReplacingMatches(in:result,range:NSRange(result.startIndex...,in:result),withTemplate:String(format:";TIME:%.0f",ceil(seconds)))
        }
        return result
    }
    private static func boundsReport(_ b:Bounds)->[String:[Double]] { ["min":[b.min.x,b.min.y,b.min.z],"max":[b.max.x,b.max.y,b.max.z]] }
    private static func adhesionMargin(_ settings:[String:String])->Double {
        switch settings["adhesion_type"] ?? "none" {
        case "raft": return Double(settings["raft_margin"] ?? "15") ?? 15
        case "brim": return Double(settings["brim_width"] ?? "8") ?? 8
        case "skirt":
            let gap:Double = Double(settings["skirt_gap"] ?? "3") ?? 3
            let lineCount:Double = Double(settings["skirt_line_count"] ?? "1") ?? 1
            let lineWidth:Double = Double(settings["skirt_brim_line_width"] ?? "0.4") ?? 0.4
            return gap + lineCount * lineWidth
        default: return 0
        }
    }
    private static func sliceFromCommandLine() throws {
        let args=CommandLine.arguments,resources=Bundle.main.resourceURL!
        let document=try JSONDecoder().decode(ProfileDocument.self,from:Data(contentsOf:resources.appendingPathComponent("Profiles.json")))
        guard let profile=document.profiles.first(where:{ $0.id==args[2] }) else { throw AppError(message:"Unknown printer profile: \(args[2])") }
        let materialID=args[3]
        guard let snapshot=profile.materialSettings?[materialID],profile.materialIDs?.contains(materialID) ?? true else { throw AppError(message:"Unknown material for this printer: \(materialID)") }
        let overrides=args.count>6 ? try JSONDecoder().decode([String:String].self,from:Data(args[6].utf8)):[:]
        let literals=Set(document.materials?.first(where:{ $0.id==materialID })?.settings.keys.map { $0 } ?? [])
        var settings=try NativeSettingsResolver.resolve(snapshot:snapshot,expressions:profile.expressions ?? [:],overrides:overrides,literalKeys:literals)
        for key in ["layer_height","layer_height_0","speed_print"] { guard let value=Double(settings[key] ?? ""),value.isFinite,value>0 else { throw AppError(message:"Invalid numeric setting: \(key)") } }
        let mesh=try MeshIO.read(URL(fileURLWithPath:args[4])),original=mesh.bounds
        guard original.size.x>0.000001,original.size.y>0.000001,original.size.z>0.000001 else { throw AppError(message:"The model has zero thickness or no printable volume.") }
        var transform=ModelTransform(); transform.position=V3(x:-original.center.x,y:-original.center.y,z:-original.min.z)
        let vertices=mesh.vertices.map(transform.apply),bounds=Bounds(vertices),margin=adhesionMargin(settings)
        guard bounds.min.x >= -profile.bedWidth/2+margin-0.05,bounds.max.x<=profile.bedWidth/2-margin+0.05,bounds.min.y >= -profile.bedDepth/2+margin-0.05,bounds.max.y<=profile.bedDepth/2-margin+0.05,bounds.max.z<=profile.bedHeight+0.05 else { throw AppError(message:"The model or its raft/brim exceeds the selected printer's build volume.") }
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("CubiconNative-CLI-\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let input=directory.appendingPathComponent("model.stl"),rawOutput=directory.appendingPathComponent("engine.gcode"),output=URL(fileURLWithPath:args[5])
        try MeshIO.writeBinarySTL(vertices:vertices,to:input)
        settings["mesh_position_x"]="0"; settings["mesh_position_y"]="0"; settings["mesh_position_z"]="0"; settings["center_object"]="false"
        if let start=profile.startGcode { settings["machine_start_gcode"]=start }; if let end=profile.endGcode { settings["machine_end_gcode"]=end }
        let service=SliceService(),started=Date()
        var result:Result<String,Error>?
        service.run(resources:resources,model:input,output:rawOutput,settings:settings,log:{ FileHandle.standardError.write(Data($0.utf8)) }) { result=$0 }
        while result == nil,Date().timeIntervalSince(started)<180 { RunLoop.current.run(until:Date(timeIntervalSinceNow:0.025)) }
        guard let finished=result else { service.cancel(); throw AppError(message:"Slicing exceeded the 180-second command-line limit.") }
        let raw=try finished.get(),path=Toolpath.parse(raw)
        try validateToolpath(path,profile:profile,settings:settings)
        let processed=normalizeGcodeHeader(raw,path:path,settings:settings)
        try processed.write(to:output,atomically:true,encoding:.utf8)
        var filament:[String:Double]=["extruder_net_mm":path.extruderNetMM]
        if let diameter=Double(settings["material_diameter"] ?? ""),diameter>0,diameter.isFinite { filament["diameter_mm"]=diameter; filament["net_volume_mm3"]=max(0,path.extruderNetMM)*Double.pi*diameter*diameter/4 }
        var report:[String:Any]=["status":"passed","profile":profile.id,"material":materialID,"engine":"native ARM64 CuraEngine","model":mesh.name,"triangle_count":mesh.triangleCount,"model_bounds_centered_mm":boundsReport(bounds),"layer_count":path.modelLayerCount,"raft_layer_count":path.raftLayerCount,"extrusion_move_count":path.totalMoves,"filament":filament,"output":output.path,"output_bytes":processed.utf8.count,"elapsed_seconds":Date().timeIntervalSince(started),"gcode_header_normalized":true]
        if let commanded=path.extrusionBounds { report["commanded_extrusion_bounds_mm"]=boundsReport(commanded) }; if let logical=logicalBounds(path,settings:settings) { report["logical_extrusion_bounds_mm"]=boundsReport(logical) }
        let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]); FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
    }

    static func main() {
        if CommandLine.arguments.count >= 6,CommandLine.arguments[1] == "--slice-model" {
            do { try sliceFromCommandLine() }
            catch { FileHandle.standardError.write(Data((error.localizedDescription+"\n").utf8)); exit(1) }
            return
        }
        if CommandLine.arguments.count >= 5, CommandLine.arguments[1] == "--inspect-settings" {
            do {
                let resources=Bundle.main.resourceURL!
                let document=try JSONDecoder().decode(ProfileDocument.self,from:Data(contentsOf:resources.appendingPathComponent("Profiles.json")))
                guard let profile=document.profiles.first(where:{ $0.id==CommandLine.arguments[2] }) else { throw AppError(message:"Unknown printer profile.") }
                let id=CommandLine.arguments[3],snapshot=profile.materialSettings?[id] ?? profile.settings
                let overrides=try JSONDecoder().decode([String:String].self,from:Data(CommandLine.arguments[4].utf8))
                let literalKeys=Set(document.materials?.first(where:{ $0.id==id })?.settings.keys.map { $0 } ?? [])
                let result=try NativeSettingsResolver.resolve(snapshot:snapshot,expressions:profile.expressions ?? [:],overrides:overrides,literalKeys:literalKeys)
                let data=try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]); FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
            } catch { FileHandle.standardError.write(Data((error.localizedDescription+"\n").utf8)); exit(1) }
            return
        }
        if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--inspect-mesh" {
            do {
                let mesh=try MeshIO.read(URL(fileURLWithPath:CommandLine.arguments[2])),b=mesh.bounds,s=b.size
                let report: [String:Any] = ["file":mesh.name,"triangle_count":mesh.triangleCount,"vertex_count":mesh.vertices.count,"bounds_min":[b.min.x,b.min.y,b.min.z],"bounds_max":[b.max.x,b.max.y,b.max.z],"dimensions_mm":[s.x,s.y,s.z]]
                let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]); FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
            } catch { FileHandle.standardError.write(Data((error.localizedDescription+"\n").utf8)); exit(1) }
            return
        }
        let app=NSApplication.shared; let delegate=NativeApp(); app.delegate=delegate; app.setActivationPolicy(.regular)
        // SceneKit/AppKit can initialize LaunchServices while the delegate is
        // being constructed. Also schedule a guarded startup after run begins.
        DispatchQueue.main.async { delegate.startInterface(reason:"runloop fallback") }
        withExtendedLifetime(delegate) { app.run() }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        startInterface(reason:"applicationDidFinishLaunching")
    }
    private func startupLog(_ message:String) {
        let directory=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/CubiconNative",isDirectory:true)
        try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let url=directory.appendingPathComponent("startup.log")
        let data=Data((ISO8601DateFormatter().string(from:Date())+" "+message+"\n").utf8)
        if !FileManager.default.fileExists(atPath:url.path) { try? data.write(to:url) }
        else if let handle=try? FileHandle(forWritingTo:url) { defer { try? handle.close() }; _ = try? handle.seekToEnd(); try? handle.write(contentsOf:data) }
    }
    private func startInterface(reason:String) {
        guard window == nil else { return }
        startupLog("Starting interface: \(reason)")
        makeMenus(); makeWindow(); setupScene()
        do {
            let document=try JSONDecoder().decode(ProfileDocument.self,from:Data(contentsOf:resources.appendingPathComponent("Profiles.json")))
            profiles=document.profiles; materials=document.materials ?? []
            guard !profiles.isEmpty else { throw AppError(message:"This app does not contain any Cubicon printer profiles.") }
            printerPopup.addItems(withTitles:["Single Plus","Style Plus A15"]); updateProfiles()
        } catch { showError(error) }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        startupLog("Shown frame=\(NSStringFromRect(window.frame)) visible=\(window.isVisible) minimized=\(window.isMiniaturized) number=\(window.windowNumber) appWindows=\(NSApp.windows.count)")
        if let pendingURL { openModel(pendingURL) }
        else if CommandLine.arguments.count > 1 { let url=URL(fileURLWithPath:CommandLine.arguments[1]); if ["stl","obj"].contains(url.pathExtension.lowercased()) { openModel(url) } }
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        guard let first=filenames.first else { sender.reply(toOpenOrPrint:.failure); return }
        let url=URL(fileURLWithPath:first)
        if window != nil { openModel(url) } else { pendingURL=url }
        sender.reply(toOpenOrPrint:.success)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication,hasVisibleWindows flag: Bool)->Bool { window.makeKeyAndOrderFront(nil); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { true }
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        if busy { showError(AppError(message:"Cancel slicing before quitting.")); return .terminateCancel }
        if unsavedGcode { window.performClose(nil); return .terminateCancel }
        return .terminateNow
    }
    func applicationWillTerminate(_ notification:Notification) { slicer.cancel(); if let temporaryDirectory { try? FileManager.default.removeItem(at:temporaryDirectory) } }
    func windowShouldClose(_ sender:NSWindow)->Bool {
        if busy { showError(AppError(message:"Cancel slicing before closing the window.")); return false }
        if unsavedGcode {
            let alert=NSAlert(); alert.messageText="Export the generated G-code before closing?"; alert.informativeText="The source model will remain unchanged."; alert.addButton(withTitle:"Export…"); alert.addButton(withTitle:"Close"); alert.addButton(withTitle:"Cancel")
            alert.beginSheetModal(for:window) { response in if response == .alertFirstButtonReturn { self.saveGcode() } else if response == .alertSecondButtonReturn { self.unsavedGcode=false; self.window.performClose(nil) } }; return false
        }
        return true
    }
    private func makeMenus() {
        let bar=NSMenu(), appItem=NSMenuItem(), appMenu=NSMenu()
        appMenu.addItem(withTitle:"About Cubicon Native",action:#selector(about),keyEquivalent:"").target=self
        appMenu.addItem(.separator()); appMenu.addItem(withTitle:"Quit Cubicon Native",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q"); appItem.submenu=appMenu; bar.addItem(appItem)
        let fileItem=NSMenuItem(), fileMenu=NSMenu(title:"File")
        for (title,selector,key) in [("Open Model…",#selector(openDocument),"o"),("Slice Model",#selector(sliceModel),"r"),("Export G-code…",#selector(saveGcode),"s")] { let item=NSMenuItem(title:title,action:selector,keyEquivalent:key); item.target=self; fileMenu.addItem(item) }
        fileItem.submenu=fileMenu; bar.addItem(fileItem)
        let editItem=NSMenuItem(), edit=NSMenu(title:"Edit")
        for (title,action,key) in [("Cut",#selector(NSText.cut(_:)),"x"),("Copy",#selector(NSText.copy(_:)),"c"),("Paste",#selector(NSText.paste(_:)),"v"),("Select All",#selector(NSText.selectAll(_:)),"a")] { edit.addItem(withTitle:title,action:action,keyEquivalent:key) }
        editItem.submenu=edit; bar.addItem(editItem); NSApp.mainMenu=bar
    }
    private func makeWindow() {
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:1280,height:850),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title="Cubicon Native"; window.minSize=NSSize(width:1000,height:700); window.center(); window.delegate=self
        let root=NSView(); window.contentView=root
        let header=NSStackView(); header.orientation = .horizontal; header.spacing=10; header.edgeInsets=NSEdgeInsets(top:12,left:16,bottom:12,right:16)
        let title=NSTextField(labelWithString:"Cubicon Native"); title.font = .boldSystemFont(ofSize:20)
        let subtitle=NSTextField(labelWithString:"Native macOS slicer for Cubicon"); subtitle.textColor = .secondaryLabelColor
        let headings=NSStackView(views:[title,subtitle]); headings.orientation = .vertical; headings.alignment = .leading; headings.spacing=2
        header.addArrangedSubview(headings); let spacer=NSView(); spacer.setContentHuggingPriority(.defaultLow,for:.horizontal); header.addArrangedSubview(spacer)
        openButton=button("Open Model…",#selector(openDocument)); sliceButton=button("Slice",#selector(sliceModel)); sliceButton.bezelColor = .controlAccentColor; sliceButton.keyEquivalent="\r"
        saveButton=button("Export G-code…",#selector(saveGcode)); saveButton.isEnabled=false
        [openButton,sliceButton,saveButton].forEach { header.addArrangedSubview($0) }
        let split=NSSplitView(); split.isVertical=true; split.dividerStyle = .thin
        let sidebar=NSScrollView(); sidebar.hasVerticalScroller=true; sidebar.drawsBackground=false
        inspector=NSStackView(); inspector.orientation = .vertical; inspector.alignment = .leading; inspector.spacing=10; inspector.edgeInsets=NSEdgeInsets(top:16,left:16,bottom:20,right:16); inspector.translatesAutoresizingMaskIntoConstraints=false
        let doc=NSView(); doc.translatesAutoresizingMaskIntoConstraints=false; sidebar.documentView=doc; doc.addSubview(inspector)
        NSLayoutConstraint.activate([doc.leadingAnchor.constraint(equalTo:sidebar.contentView.leadingAnchor),doc.topAnchor.constraint(equalTo:sidebar.contentView.topAnchor),doc.widthAnchor.constraint(equalTo:sidebar.contentView.widthAnchor),inspector.leadingAnchor.constraint(equalTo:doc.leadingAnchor),inspector.trailingAnchor.constraint(equalTo:doc.trailingAnchor),inspector.topAnchor.constraint(equalTo:doc.topAnchor),inspector.bottomAnchor.constraint(equalTo:doc.bottomAnchor)])
        inspectorSection("PRINTER")
        addPopup("Printer family",printerPopup,#selector(printerChanged)); addPopup("Machine profile",profilePopup,#selector(profileChanged)); addPopup("Material",materialPopup,#selector(materialChanged))
        inspectorSection("SLICE SETTINGS")
        addField("Layer height",layerField,suffix:"mm"); addField("First layer",firstLayerField,suffix:"mm"); addField("Infill",infillField,suffix:"%"); addField("Nozzle",nozzleField,suffix:"°C"); addField("Build plate",bedField,suffix:"°C"); addField("Print speed",speedField,suffix:"mm/s")
        supports.target=self; supports.action=#selector(settingsChanged); inspector.addArrangedSubview(supports)
        inspectorSection("MODEL")
        modelLabel.font = .systemFont(ofSize:12,weight:.medium); modelLabel.maximumNumberOfLines=3; inspector.addArrangedSubview(modelLabel)
        modelLabel.widthAnchor.constraint(equalTo:inspector.widthAnchor,constant:-32).isActive=true
        dimensionsLabel.font = .monospacedDigitSystemFont(ofSize:11,weight:.regular); dimensionsLabel.textColor = .secondaryLabelColor; inspector.addArrangedSubview(dimensionsLabel)
        for (section,defaults) in [("Position · mm",["0","0","0"]),("Rotation · °",["0","0","0"]),("Scale · %",["100","100","100"])] {
            let label=NSTextField(labelWithString:section); label.font = .systemFont(ofSize:11,weight:.medium); inspector.addArrangedSubview(label)
            let row=NSStackView(); row.orientation = .horizontal; row.spacing=6
            for i in 0..<3 {
                let field=NSTextField(string:defaults[i]); field.tag=transformFields.count; field.target=self; field.action=#selector(transformChanged); field.delegate=self; field.alignment = .right; field.widthAnchor.constraint(equalToConstant:65).isActive=true
                let group=NSStackView(views:[NSTextField(labelWithString:["X","Y","Z"][i]),field]); group.spacing=4; row.addArrangedSubview(group); transformFields.append(field)
            }
            inspector.addArrangedSubview(row)
        }
        let modelActions=NSStackView(views:[button("Center",#selector(centerModel)),button("Place on Bed",#selector(placeOnBed))]); modelActions.spacing=8; inspector.addArrangedSubview(modelActions)
        inspector.addArrangedSubview(button("Reset Transform",#selector(resetTransform)))
        let note=NSTextField(wrappingLabelWithString:"Select the exact model printed on your printer label. This build exports files; printer connection and physical printing are not implemented."); note.font = .systemFont(ofSize:11); note.textColor = .secondaryLabelColor; inspector.addArrangedSubview(note); note.widthAnchor.constraint(equalTo:inspector.widthAnchor,constant:-32).isActive=true
        split.addArrangedSubview(sidebar); sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant:310).isActive=true; sidebar.widthAnchor.constraint(lessThanOrEqualToConstant:370).isActive=true
        let right=NSView(), previewBar=NSStackView(); previewBar.orientation = .horizontal; previewBar.spacing=10; previewBar.edgeInsets=NSEdgeInsets(top:8,left:12,bottom:8,right:12)
        previewMode.selectedSegment=0; previewMode.target=self; previewMode.action=#selector(previewChanged); previewBar.addArrangedSubview(previewMode)
        layerSlider.target=self; layerSlider.action=#selector(layerChanged); layerSlider.isContinuous=true; layerSlider.isEnabled=false; previewBar.addArrangedSubview(layerSlider); previewBar.addArrangedSubview(layerLabel)
        layerSlider.widthAnchor.constraint(greaterThanOrEqualToConstant:150).isActive=true; layerLabel.widthAnchor.constraint(equalToConstant:120).isActive=true
        let logScroll=NSScrollView(); logScroll.hasVerticalScroller=true; logScroll.borderType = .bezelBorder; logView.isEditable=false; logView.font = .monospacedSystemFont(ofSize:10,weight:.regular); logView.frame=NSRect(x:0,y:0,width:700,height:125); logView.isVerticallyResizable=true; logView.isHorizontallyResizable=false; logView.autoresizingMask=[.width]; logView.textContainer?.widthTracksTextView=true; logView.textContainer?.containerSize=NSSize(width:700,height:CGFloat.greatestFiniteMagnitude); logView.string="The engine log will appear here when you slice a model.\n"; logScroll.documentView=logView
        let statusBar=NSStackView(); statusBar.orientation = .horizontal; statusBar.spacing=10; statusBar.edgeInsets=NSEdgeInsets(top:8,left:12,bottom:8,right:12)
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped=false; progress.widthAnchor.constraint(equalToConstant:16).isActive=true
        statusBar.addArrangedSubview(progress); statusBar.addArrangedSubview(status); let fill=NSView(); fill.setContentHuggingPriority(.defaultLow,for:.horizontal); statusBar.addArrangedSubview(fill)
        cancelButton=button("Cancel",#selector(cancelSlice)); cancelButton.isHidden=true; statusBar.addArrangedSubview(cancelButton)
        [sceneView,previewBar,logScroll,statusBar].forEach { $0.translatesAutoresizingMaskIntoConstraints=false; right.addSubview($0) }
        NSLayoutConstraint.activate([previewBar.leadingAnchor.constraint(equalTo:right.leadingAnchor),previewBar.trailingAnchor.constraint(equalTo:right.trailingAnchor),previewBar.topAnchor.constraint(equalTo:right.topAnchor),sceneView.leadingAnchor.constraint(equalTo:right.leadingAnchor),sceneView.trailingAnchor.constraint(equalTo:right.trailingAnchor),sceneView.topAnchor.constraint(equalTo:previewBar.bottomAnchor),logScroll.topAnchor.constraint(equalTo:sceneView.bottomAnchor),logScroll.leadingAnchor.constraint(equalTo:right.leadingAnchor,constant:10),logScroll.trailingAnchor.constraint(equalTo:right.trailingAnchor,constant:-10),logScroll.heightAnchor.constraint(equalToConstant:125),statusBar.topAnchor.constraint(equalTo:logScroll.bottomAnchor),statusBar.leadingAnchor.constraint(equalTo:right.leadingAnchor),statusBar.trailingAnchor.constraint(equalTo:right.trailingAnchor),statusBar.bottomAnchor.constraint(equalTo:right.bottomAnchor),sceneView.heightAnchor.constraint(greaterThanOrEqualToConstant:300)])
        split.addArrangedSubview(right)
        [header,split].forEach { $0.translatesAutoresizingMaskIntoConstraints=false; root.addSubview($0) }
        NSLayoutConstraint.activate([header.leadingAnchor.constraint(equalTo:root.leadingAnchor),header.trailingAnchor.constraint(equalTo:root.trailingAnchor),header.topAnchor.constraint(equalTo:root.topAnchor),split.topAnchor.constraint(equalTo:header.bottomAnchor),split.leadingAnchor.constraint(equalTo:root.leadingAnchor),split.trailingAnchor.constraint(equalTo:root.trailingAnchor),split.bottomAnchor.constraint(equalTo:root.bottomAnchor)])
        split.setPosition(320,ofDividerAt:0); sliceButton.isEnabled=false
    }
    private func inspectorSection(_ title:String) {
        if !inspector.arrangedSubviews.isEmpty { let line=NSBox(); line.boxType = .separator; inspector.addArrangedSubview(line); line.widthAnchor.constraint(equalTo:inspector.widthAnchor,constant:-32).isActive=true }
        let label=NSTextField(labelWithString:title); label.font = .systemFont(ofSize:10,weight:.semibold); label.textColor = .secondaryLabelColor; inspector.addArrangedSubview(label)
    }
    private func addPopup(_ label:String,_ popup:NSPopUpButton,_ action:Selector) {
        inspector.addArrangedSubview(NSTextField(labelWithString:label)); popup.target=self; popup.action=action; inspector.addArrangedSubview(popup); popup.widthAnchor.constraint(equalTo:inspector.widthAnchor,constant:-32).isActive=true
    }
    private func addField(_ label:String,_ field:NSTextField,suffix:String) {
        let name=NSTextField(labelWithString:label); name.widthAnchor.constraint(equalToConstant:108).isActive=true
        field.target=self; field.action=#selector(settingsChanged); field.delegate=self; field.tag = -1; field.alignment = .right; field.widthAnchor.constraint(equalToConstant:75).isActive=true
        let row=NSStackView(views:[name,field,NSTextField(labelWithString:suffix)]); row.spacing=8; inspector.addArrangedSubview(row)
    }
    private func button(_ title:String,_ action:Selector)->NSButton { let b=NSButton(title:title,target:self,action:action); b.bezelStyle = .rounded; return b }
    private func setupScene() {
        sceneView.scene=scene; sceneView.allowsCameraControl=true; sceneView.autoenablesDefaultLighting=false; sceneView.backgroundColor=NSColor(calibratedRed:0.095,green:0.115,blue:0.14,alpha:1); sceneView.antialiasingMode = .multisampling4X
        scene.rootNode.addChildNode(bedRoot); scene.rootNode.addChildNode(modelRoot); scene.rootNode.addChildNode(pathRoot)
        camera.camera=SCNCamera(); camera.camera?.fieldOfView=42; camera.camera?.zNear=0.1; camera.camera?.zFar=10000; scene.rootNode.addChildNode(camera); sceneView.pointOfView=camera
        let ambient=SCNNode(); ambient.light=SCNLight(); ambient.light?.type = .ambient; ambient.light?.intensity=600; scene.rootNode.addChildNode(ambient)
        let light=SCNNode(); light.light=SCNLight(); light.light?.type = .omni; light.light?.intensity=1100; light.position=SCNVector3(200,450,300); scene.rootNode.addChildNode(light)
    }
    private func rebuildBed() {
        bedRoot.childNodes.forEach { $0.removeFromParentNode() }
        guard let p=profile else { return }
        let plate=SCNBox(width:p.bedWidth,height:0.8,length:p.bedDepth,chamferRadius:0)
        plate.firstMaterial?.diffuse.contents=NSColor(calibratedWhite:0.22,alpha:1); plate.firstMaterial?.roughness.contents=0.9
        let node=SCNNode(geometry:plate); node.position=SCNVector3(0,-0.5,0); bedRoot.addChildNode(node)
        var lines: [(V3,V3)]=[]
        for x in stride(from:-p.bedWidth/2,through:p.bedWidth/2,by:10) { lines.append((V3(x:x,y:-p.bedDepth/2,z:0.02),V3(x:x,y:p.bedDepth/2,z:0.02))) }
        for y in stride(from:-p.bedDepth/2,through:p.bedDepth/2,by:10) { lines.append((V3(x:-p.bedWidth/2,y:y,z:0.02),V3(x:p.bedWidth/2,y:y,z:0.02))) }
        bedRoot.addChildNode(lineNode(lines,color:NSColor(calibratedWhite:0.4,alpha:1)))
        let corners=[V3(x:-p.bedWidth/2,y:-p.bedDepth/2,z:0),V3(x:p.bedWidth/2,y:-p.bedDepth/2,z:0),V3(x:p.bedWidth/2,y:p.bedDepth/2,z:0),V3(x:-p.bedWidth/2,y:p.bedDepth/2,z:0)]
        var box: [(V3,V3)]=[]
        for i in 0..<4 { let a=corners[i],b=corners[(i+1)%4],up=V3(x:0,y:0,z:p.bedHeight); box += [(a,b),(a+up,b+up),(a,a+up)] }
        bedRoot.addChildNode(lineNode(box,color:NSColor(calibratedRed:0.3,green:0.65,blue:0.75,alpha:0.45)))
        camera.position=SCNVector3(p.bedWidth*1.05,p.bedHeight*1.3,p.bedDepth*1.4); camera.look(at:SCNVector3(0,p.bedHeight*0.2,0)); sceneView.defaultCameraController.target=SCNVector3(0,p.bedHeight*0.2,0)
    }
    private func lineNode(_ lines:[(V3,V3)],color:NSColor)->SCNNode {
        let vectors=lines.flatMap { [$0.0.scene(),$0.1.scene()] }, indices=(0..<vectors.count).map(UInt32.init)
        let source=SCNGeometrySource(vertices:vectors)
        let element=SCNGeometryElement(indices:indices,primitiveType:.line)
        let geometry=SCNGeometry(sources:[source],elements:[element]); let material=SCNMaterial(); material.diffuse.contents=color; material.lightingModel = .constant; material.isDoubleSided=true; geometry.materials=[material]
        return SCNNode(geometry:geometry)
    }
    private func rebuildModel() {
        modelRoot.childNodes.forEach { $0.removeFromParentNode() }
        guard let mesh else { return }
        let vertices=mesh.vertices.map(transform.apply)
        var normals: [SCNVector3]=[]; normals.reserveCapacity(vertices.count)
        for i in stride(from:0,to:vertices.count,by:3) { let n=(vertices[i+1]-vertices[i]).cross(vertices[i+2]-vertices[i]).unit().scene(); normals.append(contentsOf:[n,n,n]) }
        let geometry=SCNGeometry(sources:[SCNGeometrySource(vertices:vertices.map { $0.scene() }),SCNGeometrySource(normals:normals)],elements:[SCNGeometryElement(indices:(0..<vertices.count).map(UInt32.init),primitiveType:.triangles)])
        let material=SCNMaterial(); material.diffuse.contents=NSColor(calibratedRed:0.14,green:0.67,blue:0.83,alpha:1); material.roughness.contents=0.65; material.isDoubleSided=true; geometry.materials=[material]
        modelRoot.addChildNode(SCNNode(geometry:geometry))
        let b=Bounds(vertices),s=b.size
        dimensionsLabel.stringValue=String(format:"%.2f × %.2f × %.2f mm\n%@ triangles",s.x,s.y,s.z,NumberFormatter.localizedString(from:NSNumber(value:mesh.triangleCount),number:.decimal))
        if let p=profile, !withinBed(b,p) { status.stringValue="Model is outside the build volume. Center, scale, or move it before slicing." } else { status.stringValue="Model ready" }
        updatePreview()
    }
    private func withinBed(_ b:Bounds,_ p:PrinterProfile)->Bool {
        let margin=Self.adhesionMargin(selectedSettings(for:p))
        return b.min.x >= -p.bedWidth/2+margin-0.05 && b.max.x <= p.bedWidth/2-margin+0.05 && b.min.y >= -p.bedDepth/2+margin-0.05 && b.max.y <= p.bedDepth/2-margin+0.05 && b.min.z >= -0.05 && b.max.z <= p.bedHeight+0.05
    }
    private func updateProfiles() {
        let family=printerPopup.titleOfSelectedItem ?? "Single Plus"
        filteredProfiles=profiles.filter { $0.family==family }; profilePopup.removeAllItems(); profilePopup.addItems(withTitles:filteredProfiles.map(\.name)); applyProfile()
    }
    private func applyProfile() {
        guard let p=profile else { sliceButton.isEnabled=false; return }
        materialPopup.removeAllItems()
        let available=materials.filter { p.materialIDs?.contains($0.id) ?? ($0.printerIDs == nil || $0.printerIDs!.contains(p.id)) }
        for material in available { materialPopup.addItem(withTitle:material.name); materialPopup.lastItem?.representedObject=material.id }
        if materialPopup.numberOfItems==0 { materialPopup.addItem(withTitle:"Profile defaults"); materialPopup.lastItem?.representedObject=p.defaultMaterialID }
        if let id=p.defaultMaterialID,let index=materialPopup.itemArray.firstIndex(where:{ ($0.representedObject as? String)==id }) { materialPopup.selectItem(at:index) }
        loadSettingsControls(selectedSettings(for:p))
        rebuildBed(); invalidateSlice(); rebuildModel(); sliceButton.isEnabled=mesh != nil && !busy
    }
    private func selectedSettings(for profile:PrinterProfile)->[String:String] {
        let id=(materialPopup.selectedItem?.representedObject as? String) ?? profile.defaultMaterialID ?? ""
        return profile.materialSettings?[id] ?? profile.settings
    }
    private func loadSettingsControls(_ settings:[String:String]) {
        func value(_ key:String,_ fallback:String)->String { settings[key] ?? fallback }
        layerField.stringValue=value("layer_height","0.2"); firstLayerField.stringValue=value("layer_height_0","0.2"); infillField.stringValue=value("infill_sparse_density","20"); nozzleField.stringValue=value("material_print_temperature","200"); bedField.stringValue=value("material_bed_temperature","60"); speedField.stringValue=value("speed_print","50"); supports.state=settings["support_enable"]=="true" ? .on:.off
    }
    @objc private func printerChanged() { if !busy { updateProfiles() } }
    @objc private func profileChanged() { if !busy { applyProfile() } }
    @objc private func materialChanged() {
        guard let p=profile else { return }
        loadSettingsControls(selectedSettings(for:p)); invalidateSlice(); rebuildModel()
    }
    @objc private func settingsChanged() { if !busy { invalidateSlice() } }
    func controlTextDidEndEditing(_ obj:Notification) { guard let field=obj.object as? NSTextField else { return }; if field.tag >= 0 { transformChanged() } else { settingsChanged() } }
    @objc private func transformChanged() {
        guard !busy,transformFields.count==9 else { return }
        let v=transformFields.map { Double($0.stringValue.replacingOccurrences(of:",",with:".")) ?? .nan }
        guard v.allSatisfy(\.isFinite),v[6]>0,v[7]>0,v[8]>0 else { transformIsValid=false; status.stringValue="Enter valid transform values; scale must be positive."; return }
        transformIsValid=true
        transform=ModelTransform(position:V3(x:v[0],y:v[1],z:v[2]),rotation:V3(x:v[3],y:v[4],z:v[5]),scale:V3(x:v[6]/100,y:v[7]/100,z:v[8]/100)); invalidateSlice(); rebuildModel()
    }
    private func displayTransform() {
        let v=[transform.position.x,transform.position.y,transform.position.z,transform.rotation.x,transform.rotation.y,transform.rotation.z,transform.scale.x*100,transform.scale.y*100,transform.scale.z*100]
        for (field,value) in zip(transformFields,v) { field.stringValue=String(format:"%.3g",value) }
    }
    @objc private func centerModel() { guard let mesh,!busy else { return }; let b=Bounds(mesh.vertices.map(transform.apply)); transform.position.x -= b.center.x; transform.position.y -= b.center.y; displayTransform(); invalidateSlice(); rebuildModel() }
    @objc private func placeOnBed() { guard let mesh,!busy else { return }; transform.position.z -= Bounds(mesh.vertices.map(transform.apply)).min.z; displayTransform(); invalidateSlice(); rebuildModel() }
    @objc private func resetTransform() { guard let mesh,!busy else { return }; let b=mesh.bounds; transform=ModelTransform(); transformIsValid=true; transform.position=V3(x:-b.center.x,y:-b.center.y,z:-b.min.z); displayTransform(); invalidateSlice(); rebuildModel() }
    @objc private func openDocument() {
        guard !busy else { return }
        let panel=NSOpenPanel(); panel.canChooseDirectories=false; panel.allowsMultipleSelection=false; panel.allowedContentTypes=[UTType(filenameExtension:"stl") ?? .data,UTType(filenameExtension:"obj") ?? .data]
        panel.beginSheetModal(for:window) { result in if result == .OK,let url=panel.url { self.openModel(url) } }
    }
    private func openModel(_ url:URL) {
        guard !busy else { return }
        setBusy(true,message:"Reading \(url.lastPathComponent)…",cancelable:false)
        DispatchQueue.global(qos:.userInitiated).async {
            let result=Result { try MeshIO.read(url) }
            DispatchQueue.main.async {
                self.setBusy(false,message:"Ready")
                switch result { case .success(let mesh): self.mesh=mesh; self.modelURL=url; self.modelLabel.stringValue=mesh.name; self.window.representedURL=url; self.window.title="\(mesh.name) — Cubicon Native"; self.resetTransform(); self.sliceButton.isEnabled=self.profile != nil
                case .failure(let error): self.showError(error) }
            }
        }
    }
    private func invalidateSlice() { gcode=nil; toolpath=nil; unsavedGcode=false; saveButton?.isEnabled=false; previewMode.selectedSegment=0; layerSlider.isEnabled=false; layerLabel.stringValue="No toolpath"; pathRoot.childNodes.forEach { $0.removeFromParentNode() }; modelRoot.opacity=1 }
    private func setBusy(_ value:Bool,message:String,cancelable:Bool=true) {
        busy=value; status.stringValue=message; openButton.isEnabled = !value; sliceButton.isEnabled = !value && mesh != nil && profile != nil; saveButton.isEnabled = !value && gcode != nil; printerPopup.isEnabled = !value; profilePopup.isEnabled = !value; cancelButton.isHidden = !value || !cancelable
        if value { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        func setControls(_ view:NSView) { for subview in view.subviews { (subview as? NSControl)?.isEnabled = !value; setControls(subview) } }
        setControls(inspector)
    }
    @objc private func sliceModel() {
        guard !busy,let mesh,let p=profile else { return }
        window.makeFirstResponder(nil); transformChanged()
        guard transformIsValid else { showError(AppError(message:"Enter valid position, rotation, and positive scale values before slicing.")); return }
        let vertices=mesh.vertices.map(transform.apply),b=Bounds(vertices)
        guard b.size.x > 0.000001,b.size.y > 0.000001,b.size.z > 0.000001 else { showError(AppError(message:"The model has zero thickness or no printable volume.")); return }
        guard withinBed(b,p) else { showError(AppError(message:"The model or its raft/brim is outside this printer's build volume. Center it, place it on the bed, or reduce its scale.")); return }
        guard let layer=Double(layerField.stringValue),layer.isFinite,layer>0,layer<=p.nozzleDiameter*1.25,let firstLayer=Double(firstLayerField.stringValue),firstLayer.isFinite,firstLayer>0,firstLayer<=p.nozzleDiameter*1.25,let infill=Double(infillField.stringValue),infill.isFinite,(0...100).contains(infill),let nozzle=Double(nozzleField.stringValue),nozzle.isFinite,(0...400).contains(nozzle),let bed=Double(bedField.stringValue),bed.isFinite,(0...150).contains(bed),let speed=Double(speedField.stringValue),speed.isFinite,speed>0 else { showError(AppError(message:"Check the slice settings. Layer height, temperatures, infill, and speed must be valid numbers.")); return }
        do {
            if let temporaryDirectory { try? FileManager.default.removeItem(at:temporaryDirectory) }
            let directory=FileManager.default.temporaryDirectory.appendingPathComponent("CubiconNative-\(UUID().uuidString)",isDirectory:true); try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true); temporaryDirectory=directory
            let input=directory.appendingPathComponent("model.stl"), output=directory.appendingPathComponent("output.gcode")
            let snapshot=selectedSettings(for:p)
            // CuraEngine MeshGroup::finalize adds the machine's half-width and
            // half-depth itself. The input remains in centered bed coordinates.
            try MeshIO.writeBinarySTL(vertices:vertices,to:input)
            let overrides:[String:String]=["layer_height":"\(layer)","layer_height_0":"\(firstLayer)","infill_sparse_density":"\(infill)","material_print_temperature":"\(nozzle)","material_print_temperature_layer_0":"\(nozzle)","material_bed_temperature":"\(bed)","material_bed_temperature_layer_0":"\(bed)","speed_print":"\(speed)","support_enable":supports.state == .on ? "true":"false"]
            let materialID=(materialPopup.selectedItem?.representedObject as? String) ?? p.defaultMaterialID ?? ""
            let literalKeys=Set(materials.first(where:{ $0.id==materialID })?.settings.keys.map { $0 } ?? [])
            var settings=try NativeSettingsResolver.resolve(snapshot:snapshot,expressions:p.expressions ?? [:],overrides:overrides,literalKeys:literalKeys)
            settings["mesh_position_x"]="0"; settings["mesh_position_y"]="0"; settings["mesh_position_z"]="0"; settings["center_object"]="false"
            if let start=p.startGcode { settings["machine_start_gcode"]=start }; if let end=p.endGcode { settings["machine_end_gcode"]=end }
            invalidateSlice(); logView.string="Printer: \(p.name)\nModel: \(mesh.name) · \(mesh.triangleCount) triangles\nNative engine started.\n"; setBusy(true,message:"Slicing \(mesh.name)…")
            slicer.run(resources:resources,model:input,output:output,settings:settings,log:{ self.appendLog($0) }) { result in
                self.setBusy(false,message:"Ready")
                switch result {
                case .success(let code):
                    let path=Toolpath.parse(code)
                    guard path.totalMoves > 0,!path.layers.isEmpty else { self.status.stringValue="The model produced no printable toolpath."; self.showError(AppError(message:"The engine generated no extrusion paths for this model.")); return }
                    do { try Self.validateToolpath(path,profile:p,settings:settings) } catch { self.status.stringValue="The generated toolpath is outside the build volume."; self.showError(error); return }
                    let normalized=Self.normalizeGcodeHeader(code,path:path,settings:settings)
                    self.gcode=normalized; self.unsavedGcode=true; self.toolpath=path; self.saveButton.isEnabled=true; let count=path.layers.count; self.layerSlider.maxValue=Double(max(0,count-1)); self.layerSlider.doubleValue=self.layerSlider.maxValue; self.layerSlider.numberOfTickMarks=0; self.layerSlider.isEnabled=count>0; self.previewMode.selectedSegment=1; self.updatePreview(); let raft=path.raftLayerCount>0 ? " + \(path.raftLayerCount) raft":""; self.status.stringValue="Sliced · \(path.modelLayerCount) layers\(raft) · \(ByteCountFormatter.string(fromByteCount:Int64(normalized.utf8.count),countStyle:.file)) · ready to export"
                case .failure(let error): self.status.stringValue=error.localizedDescription; if error.localizedDescription != "Slicing cancelled." { self.showError(error) }
                }
            }
        } catch { setBusy(false,message:"Could not prepare the model"); showError(error) }
    }
    @objc private func cancelSlice() { slicer.cancel(); status.stringValue="Cancelling…" }
    private func appendLog(_ text:String) { logView.textStorage?.append(NSAttributedString(string:text,attributes:[.font:NSFont.monospacedSystemFont(ofSize:10,weight:.regular)])); if logView.string.count > 200_000 { logView.string=String(logView.string.suffix(150_000)) }; logView.scrollToEndOfDocument(nil) }
    @objc private func previewChanged() { updatePreview() }
    @objc private func layerChanged() { updatePreview() }
    private func updatePreview() {
        pathRoot.childNodes.forEach { $0.removeFromParentNode() }
        let showing=previewMode.selectedSegment==1
        modelRoot.opacity=showing ? 0.13:1
        guard showing,let path=toolpath,let p=profile,!path.layers.isEmpty else { return }
        let index=min(path.layers.count-1,max(0,Int(layerSlider.doubleValue.rounded()))),number=path.layerNumbers[index]
        layerLabel.stringValue=number<0 ? "Raft \(index+1) / \(path.raftLayerCount)":"Layer \(number+1) / \(path.modelLayerCount)"
        let settings=selectedSettings(for:p),centerIsZero=settings["machine_center_is_zero"]=="true", origin=centerIsZero ? V3.zero:V3(x:-p.bedWidth/2,y:-p.bedDepth/2,z:0)
        let offset=origin+Self.nozzleOffset(settings)
        let lines=path.layers[index].map { ($0.0+offset,$0.1+offset) }
        pathRoot.addChildNode(lineNode(lines,color:NSColor(calibratedRed:1,green:0.76,blue:0.23,alpha:1)))
    }
    @objc private func saveGcode() {
        guard let code=gcode,!busy else { return }
        let panel=NSSavePanel(); panel.allowedContentTypes=[UTType(filenameExtension:"gcode") ?? .plainText]; panel.nameFieldStringValue=(modelURL?.deletingPathExtension().lastPathComponent ?? "Cubicon")+".gcode"
        panel.beginSheetModal(for:window) { result in if result == .OK,let url=panel.url { do { try code.write(to:url,atomically:true,encoding:.utf8); self.unsavedGcode=false; self.status.stringValue="Exported \(url.lastPathComponent)" } catch { self.showError(error) } } }
    }
    private func showError(_ error:Error) { let alert=NSAlert(); alert.alertStyle = .warning; alert.messageText="Cubicon Native"; alert.informativeText=error.localizedDescription; if window != nil { alert.beginSheetModal(for:window) } else { alert.runModal() } }
    @objc private func about() { NSApp.orderFrontStandardAboutPanel(options:[.applicationName:"Cubicon Native",.applicationVersion:"0.1",.credits:NSAttributedString(string:"Native macOS front end for Cubicon printer profiles.\nIndependent implementation; not an official CUBICON release.\nSlicing is performed by the bundled native C++ engine.")]) }
}
