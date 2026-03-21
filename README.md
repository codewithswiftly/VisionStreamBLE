# 🎥 VisionStreamBLE

> ⚡ BLE-powered connection + 📡 hotspot streaming + 🧠 on-device vision

VisionStreamBLE is a dual-app iOS system that enables **real-time video streaming between devices**, using **Bluetooth Low Energy (BLE)** for signaling and **Wi-Fi hotspot** for high-speed data transfer.  
It also integrates **on-device machine learning** for object detection and color analysis.

---

## 🚀 Features

- 📡 **Real-time video streaming**
- 🔗 **BLE-based device discovery & communication**
- 🌐 **Hotspot-based high-speed data transfer**
- 🧠 **On-device object detection (Core ML)**
- 🎨 **Color detection from video frames**
- ⚡ **Low-latency streaming pipeline**
- 🔄 **Custom NALU parsing & frame reassembly**

---

## 🏗️ Architecture
Streamer App
│
├── Capture Video (AVFoundation)
├── Encode Frames (VideoToolbox)
├── Packetize (NALU → UDP)
│
▼
Hotspot Network (Wi-Fi)
▲
│
Viewer App
├── Receive UDP Packets
├── Reassemble Frames
├── Decode Video
├── Object Detection (Core ML)
└── Display Stream


### BLE Role
- Device discovery
- Connection handshake
- Metadata transfer (e.g., object selection)

---

## 📱 Apps Included

### 🎥 Streamer App
- Captures live video
- Encodes frames into H.264
- Sends packets over hotspot network
- Advertises services via BLE

### 📺 Viewer App
- Connects via BLE
- Receives and reassembles video packets
- Decodes and renders frames
- Runs ML-based object detection

---

## 🧠 Machine Learning

- Object detection using **Core ML**
- Real-time inference on incoming frames
- Object name can be sent back via BLE
- Color extraction using pixel analysis

---

## 🛠️ Tech Stack

- **Swift**
- **AVFoundation** – Video capture
- **VideoToolbox** – Encoding/decoding
- **CoreBluetooth** – BLE communication
- **Network / UDP** – Data transfer
- **Core ML / Vision** – Object detection
- **Core Image** – Frame processing

---

## 📂 Project Structure
VisionStreamBLE/
│
├── MetaStreamerAppStoryboard/
├── MetaViewerAppStoryboard/
├── Docs/
└── README.md

---

## ⚙️ Setup Instructions

   1. Clone the repository:
    ```bash
   git clone https://github.com/your-username/VisionStreamBLE.git

	2	Open in Xcode:  open MetaViewerAppStoryboard.xcodeproj and 
	3	open MetaStreamerAppStoryboard.xcodeproj 
	4	Run on two real iOS devices:
	◦	One as Streamer
	◦	One as Viewer
⚠️ Note:
	•	BLE and hotspot require physical devices (not simulator)
	•	Ensure both devices are on the same hotspot network

📌 Use Cases
	•	📹 Remote video monitoring
	•	🤖 Edge AI applications
	•	🕶️ Smart wearable integrations
	•	🎯 Real-time object tracking systems
	•	🔬 Experimental networking & streaming research

🔮 Future Improvements
	•	Adaptive bitrate streaming
	•	HEVC support
	•	Multi-device streaming
	•	Audio streaming support
	•	Cloud relay fallback
	•	UI enhancements

🤝 Contributing
Contributions are welcome! Feel free to open issues or submit pull requests.

📄 License
This project is licensed under the MIT License.

👨‍💻 Author
Rahul Dasgupta

⭐️ Show Your Support
If you found this project useful, consider giving it a ⭐️ on GitHub!


