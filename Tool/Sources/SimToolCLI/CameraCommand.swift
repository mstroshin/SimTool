import ArgumentParser
import Foundation
import SimToolClient
import SimToolCore
import SimToolStream

struct Camera: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "camera",
        abstract: "Give the simulator a camera: an image, a video in a loop, or the Mac's webcam — or turn it off.",
        discussion: """
        The simulator has no camera. SimTool gives one to the apps it launches \
        (`simtool app launch`, the viewer's Relaunch, test runs): previews, video \
        frames, photos, QR and barcode scanning and UIImagePickerController's \
        camera show the picture chosen here, as the back and the front camera.

          simtool camera code.png           # an image: a QR code, a document, a card
          simtool camera clip.mov           # a video, played in a loop
          simtool camera webcam             # the Mac's camera; macOS asks once
          simtool camera webcam --camera iPhone
          simtool camera off
          simtool camera                    # what it shows and which apps have it
          simtool camera env                # the variables for an Xcode scheme

        A new picture reaches running apps at once. An app launched while the \
        camera was off gets it at its next launch through SimTool; an app run \
        from Xcode gets it with the variables `simtool camera env` prints in its \
        scheme's Run › Arguments › Environment Variables. With a server watching \
        the device, the server keeps the webcam running; without one, \
        `simtool camera webcam` runs until Ctrl+C.
        """
    )

    @Argument(help: "An image or a video, webcam, off, or env. Nothing: show the camera.") var source: String?
    @Option(help: "With webcam: the Mac camera's id, or a part of its name.") var camera: String?
    @Option var device: String?
    @OptionGroup var common: CommonJSON

    func validate() throws {
        if camera != nil, source?.lowercased() != "webcam" { throw ValidationError("--camera goes with webcam") }
    }

    func run() async throws {
        let device = try await resolveDeviceToDrive(device)
        let udid = device.udid
        // The webcam feeds the simulator until Ctrl-C: in use all along.
        let heartbeat = SimulatorHold.keepAlive(udid)
        defer { heartbeat.cancel() }
        // A server watching the device owns the camera: it runs the webcam and
        // tells its viewers.
        let server = ActivityReporter(device: device).servers.first.map { SimToolClient(baseURL: $0) }
        switch source?.lowercased() {
        case nil:
            var state = try await server?.camera() ?? SimulatorCamera.state(deviceUDID: udid)
            if state.macCameras == nil { state.macCameras = MacCameraFeed.cameras() }
            try show(state)
        case "off":
            try show(try await server?.cameraOff() ?? SimulatorCamera.off(deviceUDID: udid))
        case "env":
            let environment = [
                "DYLD_INSERT_LIBRARIES": try await SimulatorCamera.injectorURL().path,
                "SIMTOOL_CAMERA_DIR": SimulatorCamera.directory(deviceUDID: udid).path,
            ]
            if common.json { try printJSON(environment); return }
            for (name, value) in environment.sorted(by: { $0.key < $1.key }) { print("\(name)=\(value)") }
        case "webcam":
            if let server {
                try show(try await server.setCameraWebcam(camera: camera))
                return
            }
            let feed = try await MacCameraFeed.start(camera: camera, deviceUDID: udid)
            SignalTrap.shared.installCleanup {
                feed.stop()
                _ = try? SimulatorCamera.off(deviceUDID: udid)
            }
            try show(try await SimulatorCamera.setWebcam(name: feed.camera.name, deviceUDID: udid))
            FileHandle.standardError.write(Data("The camera shows the Mac's \(feed.camera.name) until Ctrl+C.\n".utf8))
            while true { try await Task.sleep(for: .seconds(3600)) }
        default:
            let file = URL(fileURLWithPath: (source! as NSString).expandingTildeInPath)
            if let server {
                try show(try await server.setCamera(file: file))
            } else {
                try show(try await SimulatorCamera.setFile(file, deviceUDID: udid))
            }
        }
    }

    private func show(_ state: SimulatorCameraState) throws {
        if common.json { try printJSON(state); return }
        var lines: [(String, String)] = [("camera", state.summary)]
        let apps = state.apps.map { "\($0.bundleId) (pid \($0.pid)\($0.running ? ", capturing" : ""))" }.joined(separator: ", ")
        if state.source != .none {
            lines.append(("apps", state.apps.isEmpty ? "none yet — an app gets the camera at its next launch through SimTool (simtool app launch)" : apps))
        } else if !state.apps.isEmpty {
            lines.append(("apps", apps + " — black until the camera shows something again"))
        }
        if let cameras = state.macCameras {
            lines.append(("mac cameras", cameras.isEmpty ? "none" : cameras.map(\.name).joined(separator: ", ")))
        }
        let width = lines.map(\.0.count).max() ?? 0
        for (name, value) in lines { print(name.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + value) }
    }
}
