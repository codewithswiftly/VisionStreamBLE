// ViewerViewController.swift — ViewerApp
// Orchestrates BLE → WiFi join → UDP receive → H264 decode → render pipeline.
// UI: full-screen video, status HUD overlay, Connect button.

import UIKit
import CoreMedia
import Network

final class ViewerViewController: UIViewController {

    // MARK: - Pipeline components
    private let bleManager   = BLECentralManager()
    private let wifiManager  = WiFiManager()
    private let udpReceiver  = UDPReceiver()
    private let naluParser   = NALUParser()
    private let decoder      = H264Decoder()
    private let videoRenderer = VideoRenderer()

    // MARK: - State
    private var isConnected  = false
    private var credentials: WiFiCredentials?
    private var latencyMs: Double = 0
    private var decodedFrames = 0
    private var lastStatTime  = Date()
    private var statsTimer: Timer?

    // MARK: - UI
    private let hudView         = UIView()
    private let statusLabel     = UILabel()
    private let statsLabel      = UILabel()
    private let connectButton   = UIButton(type: .system)
    private let spinner         = UIActivityIndicatorView(style: .large)
    private let noSignalView    = UIView()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupUI()
        setupPipeline()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        disconnect()
    }

    // MARK: - Pipeline setup

    private func setupPipeline() {
        bleManager.delegate   = self
        wifiManager.delegate  = self
        udpReceiver.delegate  = self
        naluParser.delegate   = self
        decoder.delegate      = self
    }

    // MARK: - Connect / Disconnect

    @objc private func connectTapped() {
        if isConnected { disconnect(); return }
        updateStatus("Scanning for glasses…", color: .systemYellow)
        spinner.startAnimating()
        connectButton.isEnabled = false
        bleManager.startScanning()
    }

    private func beginReceiving() {
        do {
            try udpReceiver.startListening()
            updateStatus("📡 Receiving…", color: .systemGreen)
            startStatsTimer()
        } catch {
            updateStatus("⚠️ UDP error: \(error.localizedDescription)", color: .systemRed)
        }
    }

    private func disconnect() {
        bleManager.stopScanning()
        bleManager.disconnect()
        udpReceiver.stopListening()
        decoder.flush()
        decoder.invalidate()
        naluParser.reset()
        videoRenderer.flushAndRemoveImage()
        statsTimer?.invalidate()
        isConnected = false
        spinner.stopAnimating()
        connectButton.isEnabled = true
        connectButton.setTitle("Connect Glasses", for: .normal)
        connectButton.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.85)
        noSignalView.isHidden = false
        updateStatus("Tap to connect", color: .white)
        statsLabel.text = "—"
    }

    // MARK: - Stats

    private func startStatsTimer() {
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateStats()
        }
    }

    private func updateStats() {
        let elapsed = Date().timeIntervalSince(lastStatTime)
        let fps     = elapsed > 0 ? Double(decodedFrames) / elapsed : 0
        let lost    = udpReceiver.lostFrameCount
        statsLabel.text = String(format: "%.1f fps  |  loss: %d  |  pkts: %d",
                                 fps, lost, udpReceiver.receivedPacketCount)
        decodedFrames = 0
        lastStatTime  = Date()
    }

    // MARK: - Helpers

    private func updateStatus(_ text: String, color: UIColor) {
        DispatchQueue.main.async { [weak self] in
            self?.statusLabel.text  = text
            self?.statusLabel.textColor = color
        }
    }

    // MARK: - UI Layout

    private func setupUI() {
        // Full-screen video renderer
        videoRenderer.translatesAutoresizingMaskIntoConstraints = false
        videoRenderer.alpha = 0   // hidden until first frame
        view.addSubview(videoRenderer)
        NSLayoutConstraint.activate([
            videoRenderer.topAnchor.constraint(equalTo: view.topAnchor),
            videoRenderer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            videoRenderer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoRenderer.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        // No-signal placeholder
        noSignalView.translatesAutoresizingMaskIntoConstraints = false
        noSignalView.backgroundColor = UIColor(white: 0.05, alpha: 1)
        view.addSubview(noSignalView)
        NSLayoutConstraint.activate([
            noSignalView.topAnchor.constraint(equalTo: view.topAnchor),
            noSignalView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            noSignalView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            noSignalView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        // Glasses icon label
        let glassesLabel = UILabel()
        glassesLabel.text = "⬛️  Meta Glasses"
        glassesLabel.textColor = UIColor.white.withAlphaComponent(0.3)
        glassesLabel.font = .systemFont(ofSize: 22, weight: .thin)
        glassesLabel.textAlignment = .center
        glassesLabel.translatesAutoresizingMaskIntoConstraints = false
        noSignalView.addSubview(glassesLabel)
        NSLayoutConstraint.activate([
            glassesLabel.centerXAnchor.constraint(equalTo: noSignalView.centerXAnchor),
            glassesLabel.centerYAnchor.constraint(equalTo: noSignalView.centerYAnchor)
        ])

        // Spinner
        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20)
        ])

        // HUD at bottom
        hudView.translatesAutoresizingMaskIntoConstraints = false
        hudView.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        hudView.layer.cornerRadius = 16
        view.addSubview(hudView)
        NSLayoutConstraint.activate([
            hudView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            hudView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            hudView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20)
        ])

        statusLabel.text = "Tap to connect"
        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 14, weight: .medium)
        statusLabel.textAlignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        statsLabel.text = "—"
        statsLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        statsLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        statsLabel.textAlignment = .center
        statsLabel.translatesAutoresizingMaskIntoConstraints = false

        connectButton.setTitle("Connect Glasses", for: .normal)
        connectButton.setTitleColor(.white, for: .normal)
        connectButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        connectButton.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.85)
        connectButton.layer.cornerRadius = 12
        connectButton.translatesAutoresizingMaskIntoConstraints = false
        connectButton.addTarget(self, action: #selector(connectTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [statusLabel, statsLabel, connectButton])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        hudView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: hudView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: hudView.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: hudView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: hudView.trailingAnchor, constant: -16),
            connectButton.heightAnchor.constraint(equalToConstant: 50)
        ])

        // Title
        let titleLabel = UILabel()
        titleLabel.text = "Meta View — Viewer"
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16)
        ])
    }
}

// MARK: - BLECentralManagerDelegate
extension ViewerViewController: BLECentralManagerDelegate {

    func bleCentral(_ manager: BLECentralManager, didReceiveCredentials credentials: WiFiCredentials) {
        self.credentials = credentials
        updateStatus("Joining hotspot '\(credentials.ssid)'…", color: .systemYellow)
        wifiManager.joinHotspot(ssid: credentials.ssid, password: credentials.password)
    }

    func bleCentral(_ manager: BLECentralManager, didUpdateStatus status: BLEScanStatus) {
        switch status {
        case .scanning:
            updateStatus("🔵 Scanning for glasses…", color: .systemBlue)
        case .connecting:
            updateStatus("Connecting to glasses…", color: .systemYellow)
        case .connected:
            updateStatus("Connected — reading credentials…", color: .systemGreen)
        case .credentialsReceived:
            updateStatus("Credentials received", color: .systemGreen)
        case .error(let msg):
            updateStatus("⚠️ \(msg)", color: .systemRed)
            DispatchQueue.main.async { [weak self] in
                self?.spinner.stopAnimating()
                self?.connectButton.isEnabled = true
            }
        case .idle:
            break
        }
    }
}

// MARK: - WiFiManagerDelegate
extension ViewerViewController: WiFiManagerDelegate {

    func wifiManager(_ manager: WiFiManager, didJoinSSID ssid: String, assignedIP: String) {
        NSLog("[ViewerVC] Joined hotspot, assigned IP: %@", assignedIP)
        updateStatus("📶 On hotspot — starting stream…", color: .systemGreen)

        // Tell the streamer our IP so it knows where to send UDP
        bleManager.notifyStreamerReady(viewerIP: assignedIP)

        isConnected = true
        connectButton.isEnabled = true
        connectButton.setTitle("Disconnect", for: .normal)
        connectButton.backgroundColor = UIColor.systemRed.withAlphaComponent(0.85)
        spinner.stopAnimating()
        noSignalView.isHidden = true

        beginReceiving()
    }

    func wifiManager(_ manager: WiFiManager, didFailWithError error: Error) {
        // Hotspot join failed — guide user to connect manually
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.spinner.stopAnimating()
            self.connectButton.isEnabled = true
            let ssid = self.credentials?.ssid ?? "Glasses Hotspot"
            let ip   = self.credentials?.streamerIP ?? "172.20.10.1"

            let alert = UIAlertController(
                title: "Join Hotspot Manually",
                message: "Go to Settings → WiFi and join '\(ssid)'.\nStreamer IP: \(ip)\n\nThen return here and tap 'I'm Connected'.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "I'm Connected", style: .default) { [weak self] _ in
                guard let self else { return }
                if let myIP = self.wifiManager.localIPAddress() {
                    self.bleManager.notifyStreamerReady(viewerIP: myIP)
                    self.isConnected = true
                    self.noSignalView.isHidden = true
                    self.beginReceiving()
                }
            })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
                self?.disconnect()
            })
            self.present(alert, animated: true)
        }
    }
}

// MARK: - UDPReceiverDelegate
extension ViewerViewController: UDPReceiverDelegate {

    func udpReceiver(_ receiver: UDPReceiver,
                     didReceiveNALUnit payload: Data,
                     header: UDPPacketHeader) {
        naluParser.process(payload: payload, header: header)
    }

    func udpReceiver(_ receiver: UDPReceiver, didChangeState listening: Bool) {
        NSLog("[ViewerVC] UDP receiver listening: %@", listening ? "YES" : "NO")
    }
}

// MARK: - NALUParserDelegate
extension ViewerViewController: NALUParserDelegate {

    func naluParser(_ parser: NALUParser, didUpdateFormatDescription desc: CMFormatDescription) {
        decoder.updateFormatDescription(desc)
    }

    func naluParser(_ parser: NALUParser,
                    didProduceSampleBuffer buffer: CMSampleBuffer,
                    isKeyFrame: Bool) {
        decoder.decode(sampleBuffer: buffer)
    }
}

// MARK: - H264DecoderDelegate
extension ViewerViewController: H264DecoderDelegate {

    func decoder(_ decoder: H264Decoder,
                 didDecodePixelBuffer pixelBuffer: CVPixelBuffer,
                 presentationTime: CMTime) {
        // Compute approximate end-to-end latency
        let wallNow   = Date().timeIntervalSince1970
        let frameTime = presentationTime.seconds
        let latency   = max(0, (wallNow - frameTime)) * 1000   // ms
        self.latencyMs = latency * 0.1 + self.latencyMs * 0.9  // EMA

        decodedFrames += 1

        // Render on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.videoRenderer.render(
                pixelBuffer:       pixelBuffer,
                presentationTime:  presentationTime,
                formatDescription: self.decoder.currentFormatDescription
            )
            self.videoRenderer.alpha = 1
            self.noSignalView.isHidden = true
        }
    }

    func decoder(_ decoder: H264Decoder, didFailWithError error: Error) {
        NSLog("[ViewerVC] Decoder error: %@", error.localizedDescription)
        updateStatus("Decoder error — reconnecting…", color: .systemOrange)
    }
}

// MARK: - Expose currentFormatDescription for rendering
extension H264Decoder {
    var currentFormatDescription: CMFormatDescription? {
        // We need to expose this for the renderer's pixelBuffer path
        // Access via a stored property set during session creation
        return nil   // The CMSampleBuffer path in NALUParser carries its own fmtDesc
    }
}
