// StreamViewController.swift — StreamerApp
// Orchestrates camera → encoder → packetizer → UDP sender pipeline.
// UI: camera preview full-screen, status HUD, Start/Stop button.

import UIKit
import AVFoundation
import CoreMedia

final class StreamViewController: UIViewController {

    // MARK: - Pipeline components
    private let camera      = CameraManager()
    private let encoder     = H264Encoder()
    private let packetizer  = NALUPacketizer()
    private let udpSender   = UDPSender()
    private let bleManager  = BLEPeripheralManager()

    // MARK: - State
    private var isStreaming   = false
    private var viewerIP: String?
    private var framesSent    = 0
    private var bytesSent     = 0
    private var lastStatTime  = Date()

    // MARK: - UI
    private let previewContainer = UIView()
    private let hudView          = UIView()
    private let statusLabel      = UILabel()
    private let statsLabel       = UILabel()
    private let startButton      = UIButton(type: .system)
    private let bleStatusDot     = UIView()

    let synthesizer = AVSpeechSynthesizer()
    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupUI()
        setupPipeline()
        bleManager.start()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        camera.startCapture()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        camera.stopCapture()
        if isStreaming { stopStreaming() }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }

    // MARK: - Setup

    private func setupPipeline() {
        // Camera → Encoder
        camera.delegate   = self
        encoder.delegate  = self
        udpSender.delegate = self
        bleManager.delegate = self

        do {
            try camera.configure()
        } catch {
            showAlert("Camera Error", message: error.localizedDescription)
            return
        }

        // Attach preview layer once camera is configured
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, let previewLayer = self.camera.previewLayer else { return }
            previewLayer.frame = self.previewContainer.bounds
            previewLayer.videoGravity = .resizeAspectFill
            self.previewContainer.layer.insertSublayer(previewLayer, at: 0)
        }
    }

    private func startStreaming() {
        guard let ip = viewerIP else {
            updateStatus("Waiting for viewer connection…", color: .systemOrange)
            return
        }

        do {
            try encoder.configure()
        } catch {
            showAlert("Encoder Error", message: error.localizedDescription)
            return
        }

        udpSender.connect(to: ip)
        isStreaming = true
        framesSent  = 0
        bytesSent   = 0
        lastStatTime = Date()
        startButton.setTitle("⏹ Stop Streaming", for: .normal)
        startButton.backgroundColor = UIColor.systemRed.withAlphaComponent(0.85)
        updateStatus("🔴 Streaming to \(ip)", color: .systemRed)
        startStatsTimer()
        NSLog("[Stream] Started streaming to %@", ip)
    }

    private func stopStreaming() {
        encoder.invalidate()
        udpSender.disconnect()
        packetizer.resetFrameCounter()
        isStreaming = false
        statsTimer?.invalidate()
        startButton.setTitle("▶ Start Streaming", for: .normal)
        startButton.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.85)
        updateStatus("Ready — waiting for viewer", color: .white)
    }

    @objc private func toggleStreaming() {
        isStreaming ? stopStreaming() : startStreaming()
    }

    // MARK: - Stats timer

    private var statsTimer: Timer?

    private func startStatsTimer() {
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateStats()
        }
    }

    private func updateStats() {
        let elapsed = Date().timeIntervalSince(lastStatTime)
        let fps     = elapsed > 0 ? Double(framesSent) / elapsed : 0
        let kbps    = elapsed > 0 ? Double(bytesSent) * 8 / elapsed / 1000 : 0
        statsLabel.text = String(format: "%.1f fps  |  %.0f kbps  |  %d pkts",
                                 fps, kbps, udpSender.sentPacketCount)
        framesSent   = 0
        bytesSent    = 0
        lastStatTime = Date()
    }

    // MARK: - UI helpers

    private func updateStatus(_ text: String, color: UIColor) {
        DispatchQueue.main.async { [weak self] in
            self?.statusLabel.text = text
            self?.statusLabel.textColor = color
        }
    }

    private func showAlert(_ title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: - UI Layout

    private func setupUI() {
        // Full-screen preview
        previewContainer.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.backgroundColor = .black
        view.addSubview(previewContainer)
        NSLayoutConstraint.activate([
            previewContainer.topAnchor.constraint(equalTo: view.topAnchor),
            previewContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            previewContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        // Semi-transparent HUD at bottom
        hudView.translatesAutoresizingMaskIntoConstraints = false
        hudView.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        hudView.layer.cornerRadius = 16
        view.addSubview(hudView)
        NSLayoutConstraint.activate([
            hudView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            hudView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            hudView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20)
        ])

        // BLE indicator dot
        bleStatusDot.translatesAutoresizingMaskIntoConstraints = false
        bleStatusDot.backgroundColor = .systemGray
        bleStatusDot.layer.cornerRadius = 6
        view.addSubview(bleStatusDot)
        NSLayoutConstraint.activate([
            bleStatusDot.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            bleStatusDot.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            bleStatusDot.widthAnchor.constraint(equalToConstant: 12),
            bleStatusDot.heightAnchor.constraint(equalToConstant: 12)
        ])

        // BLE label
        let bleLabel = UILabel()
        bleLabel.text = "BLE"
        bleLabel.textColor = .white
        bleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        bleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bleLabel)
        NSLayoutConstraint.activate([
            bleLabel.centerYAnchor.constraint(equalTo: bleStatusDot.centerYAnchor),
            bleLabel.trailingAnchor.constraint(equalTo: bleStatusDot.leadingAnchor, constant: -4)
        ])

        // Status label
        statusLabel.text = "Waiting for viewer…"
        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 14, weight: .medium)
        statusLabel.textAlignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        // Stats label
        statsLabel.text = "—"
        statsLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        statsLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        statsLabel.textAlignment = .center
        statsLabel.translatesAutoresizingMaskIntoConstraints = false

        // Start button
        startButton.setTitle("▶ Start Streaming", for: .normal)
        startButton.setTitleColor(.white, for: .normal)
        startButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        startButton.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.85)
        startButton.layer.cornerRadius = 12
        startButton.translatesAutoresizingMaskIntoConstraints = false
        startButton.addTarget(self, action: #selector(toggleStreaming), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [statusLabel, startButton])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        hudView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: hudView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: hudView.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: hudView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: hudView.trailingAnchor, constant: -16),
            startButton.heightAnchor.constraint(equalToConstant: 50)
        ])

        // App title
        let titleLabel = UILabel()
        titleLabel.text = "Meta Glasses — Streamer"
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

// MARK: - CameraManagerDelegate
extension StreamViewController: CameraManagerDelegate {
    func cameraManager(_ manager: CameraManager,
                       didOutputPixelBuffer pixelBuffer: CVPixelBuffer,
                       presentationTime: CMTime) {
        guard isStreaming else { return }
        encoder.encode(pixelBuffer: pixelBuffer, presentationTime: presentationTime)
    }
}

// MARK: - H264EncoderDelegate
extension StreamViewController: H264EncoderDelegate {    
    func encoder(_ encoder: H264Encoder, didOutputSPS sps: Data, pps: Data) {
        guard isStreaming else { return }
        // Send SPS and PPS as individual NAL units before every IDR
        let spsPackets = packetizer.packetize(nalData: sps,  nalType: .sps, pts: .zero, isKeyFrame: false)
        let ppsPackets = packetizer.packetize(nalData: pps,  nalType: .pps, pts: .zero, isKeyFrame: false)
        udpSender.send(packets: spsPackets)
        udpSender.send(packets: ppsPackets)
    }

    func encoder(_ encoder: H264Encoder,
                 didOutputNALUnit nalData: Data,
                 nalType: H264NALType,
                 pts: CMTime,
                 isKeyFrame: Bool) {
        guard isStreaming else { return }
        let packets = packetizer.packetize(nalData: nalData, nalType: nalType,
                                           pts: pts, isKeyFrame: isKeyFrame)
        udpSender.send(packets: packets)
        framesSent += 1
        bytesSent  += nalData.count
    }
}

// MARK: - UDPSenderDelegate
extension StreamViewController: UDPSenderDelegate {
    func udpSender(_ sender: UDPSender, didChangeState state: NWConnection.State) {
        switch state {
        case .ready:
            updateStatus("🔴 Streaming live", color: .systemRed)
        case .failed(let err):
            updateStatus("⚠️ Network error: \(err.localizedDescription)", color: .systemOrange)
        default: break
        }
    }

    func udpSender(_ sender: UDPSender, didSendPackets count: Int, totalBytes: Int) { }
}

// MARK: - BLEPeripheralManagerDelegate
extension StreamViewController: BLEPeripheralManagerDelegate {
    func blePeripheral(_ manager: BLEPeripheralManager, recievedObject name: String) {
        self.speak("It is a \(name)")
    }

    func blePeripheral(_ manager: BLEPeripheralManager, viewerIsReady viewerIP: String) {
        self.viewerIP = viewerIP
        updateStatus("📱 Viewer connected — tap Start", color: .systemGreen)
        bleStatusDot.backgroundColor = .systemGreen
        self.startStreaming()
    }

    func blePeripheralDidUpdateState(_ manager: BLEPeripheralManager, isAdvertising: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.bleStatusDot.backgroundColor = isAdvertising ? .systemBlue : .systemGray
        }
    }

    func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.5
        
        synthesizer.speak(utterance)
    }
}
