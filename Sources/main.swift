// The Swift Programming Language
// https://docs.swift.org/swift-book

import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import ArgumentParser

// MARK: - Command Line Interface

struct AudioCaptureCLI: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "audio-cli",
        abstract: "A CLI tool to capture system audio",
        version: "1.0.0"
    )
    
    @Option(name: .shortAndLong, help: "Duration in seconds to record")
    var duration: Int = 10
    
    @Option(name: .shortAndLong, help: "Output file path")
    var output: String = "output.wav"
    
    @Flag(name: .shortAndLong, help: "Show verbose output")
    var verbose: Bool = false
    
    func run() throws {
        print("Starting audio capture for \(duration) seconds...")
        print("Output will be saved to: \(output)")
        
        let captureManager = AudioCaptureManager(verbose: verbose)
        
        // Set up signal handling for clean exit
        signal(SIGINT) { _ in
            print("\nReceived interrupt signal. Stopping capture...")
            captureManager.stopCapture()
            Foundation.exit(0)
        }
        
        // Start capture
        try captureManager.startCapture(outputPath: output)
        
        // Run for specified duration
        if duration > 0 {
            print("Recording for \(duration) seconds...")
            Thread.sleep(forTimeInterval: TimeInterval(duration))
            captureManager.stopCapture()
        } else {
            print("Recording until interrupted (Ctrl+C to stop)...")
            // Keep the process running until interrupted
            RunLoop.main.run()
        }
    }
}

// MARK: - Audio Capture Manager

@available(macOS 12.3, *)
class AudioCaptureManager: NSObject, SCStreamDelegate, SCStreamOutput {
    private var stream: SCStream?
    private var availableContent: SCShareableContent?
    private var isCapturing = false
    private var audioWriter: AudioFileWriter?
    private let verbose: Bool
    
    init(verbose: Bool = false) {
        self.verbose = verbose
        super.init()
    }
    
    func startCapture(outputPath: String) throws {
        // Check if already capturing
        guard !isCapturing else {
            print("Already capturing audio")
            return
        }
        
        // Initialize audio file writer
        audioWriter = try AudioFileWriter(outputPath: outputPath)
        
        // Get available content to capture
        try getAvailableContent()
        
        // Set up and start the capture stream
        try setupAndStartCaptureStream()
        
        isCapturing = true
    }
    
    func stopCapture() {
        guard isCapturing else { return }
        
        print("Stopping audio capture...")
        
        // Stop the stream
        stream?.stopCapture { error in
            if let error = error {
                print("Error stopping capture: \(error.localizedDescription)")
            }
        }
        
        // Finalize the audio file
        audioWriter?.finalize()
        audioWriter = nil
        
        isCapturing = false
        print("Audio capture stopped. File saved.")
    }
    
    private func getAvailableContent() throws {
        let semaphore = DispatchSemaphore(value: 0)
        var contentError: Error?
        
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            if let error = error {
                contentError = error
                semaphore.signal()
                return
            }
            
            self.availableContent = content
            semaphore.signal()
        }
        
        semaphore.wait()
        
        if let contentError = contentError {
            throw contentError
        }
        
        guard availableContent != nil else {
            throw NSError(domain: "AudioCaptureCLI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to get available content"])
        }
    }
    
    private func setupAndStartCaptureStream() throws {
        guard let availableContent = availableContent else {
            throw NSError(domain: "AudioCaptureCLI", code: 2, userInfo: [NSLocalizedDescriptionKey: "No available content to capture"])
        }
        
        // Get the first display for the content filter
        guard let display = availableContent.displays.first else {
            throw NSError(domain: "AudioCaptureCLI", code: 3, userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }
        
        // Create a content filter for system audio
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        
        // Configure the stream
        let configuration = SCStreamConfiguration()
        
        // Enable audio capture
        if #available(macOS 13.0, *) {
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true  // Don't capture our own audio
        } else {
            throw NSError(domain: "AudioCaptureCLI", code: 4, userInfo: [NSLocalizedDescriptionKey: "Audio capture requires macOS 13.0 or later"])
        }
        
        // Create the stream
        stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        
        // Add self as stream output to receive audio samples
        if #available(macOS 13.0, *) {
            try stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue.global(qos: .userInteractive))
        } else {
            throw NSError(domain: "AudioCaptureCLI", code: 5, userInfo: [NSLocalizedDescriptionKey: "Audio output requires macOS 13.0 or later"])
        }
        
        // Start capturing
        try stream?.startCapture()
    }
    
    // MARK: - SCStreamDelegate
    
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("Stream stopped with error: \(error.localizedDescription)")
        isCapturing = false
    }
    
    // MARK: - SCStreamOutput
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if #available(macOS 13.0, *) {
            guard type == .audio, isCapturing, let audioWriter = audioWriter else { return }
            
            if verbose {
                let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
                let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
                print("Received audio batch: \(sampleCount) samples at time \(String(format: "%.2f", timestamp))s")
            }
            
            // Write the audio sample buffer to file
            do {
                try audioWriter.write(sampleBuffer: sampleBuffer)
            } catch {
                print("Error writing audio: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Audio File Writer

class AudioFileWriter {
    private var audioFile: AVAudioFile?
    private var audioFormat: AVAudioFormat?
    private let outputPath: String
    
    init(outputPath: String) throws {
        self.outputPath = outputPath
        
        // Create directory if needed
        let directory = (outputPath as NSString).deletingLastPathComponent
        if !directory.isEmpty && directory != "." {
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }
        
        // We'll set up the audio file when we receive the first sample buffer
        // as we need to know the format
    }
    
    func write(sampleBuffer: CMSampleBuffer) throws {
        // If this is the first sample, set up the audio file
        if audioFile == nil {
            try setupAudioFile(with: sampleBuffer)
        }
        
        guard let audioFile = audioFile, let audioFormat = audioFormat else {
            throw NSError(domain: "AudioFileWriter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Audio file not initialized"])
        }
        
        // Convert CMSampleBuffer to AVAudioPCMBuffer
        let pcmBuffer = try convertToPCMBuffer(sampleBuffer: sampleBuffer, format: audioFormat)
        
        // Write the buffer to file
        try audioFile.write(from: pcmBuffer)
    }
    
    func finalize() {
        audioFile = nil
        audioFormat = nil
        print("Audio file saved to: \(outputPath)")
    }
    
    private func setupAudioFile(with sampleBuffer: CMSampleBuffer) throws {
        guard let audioFormatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw NSError(domain: "AudioFileWriter", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not get audio format description"])
        }
        
        // Get the audio stream basic description
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(audioFormatDescription)?.pointee else {
            throw NSError(domain: "AudioFileWriter", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not get audio stream basic description"])
        }
        
        // Create an AVAudioFormat from the ASBD
        audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: asbd.mSampleRate,
            channels: AVAudioChannelCount(asbd.mChannelsPerFrame),
            interleaved: false
        )
        
        guard let audioFormat = audioFormat else {
            throw NSError(domain: "AudioFileWriter", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not create audio format"])
        }
        
        // Create the audio file
        let fileURL = URL(fileURLWithPath: outputPath)
        audioFile = try AVAudioFile(
            forWriting: fileURL,
            settings: audioFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        
        print("Created audio file with format: \(audioFormat)")
    }
    
    private func convertToPCMBuffer(sampleBuffer: CMSampleBuffer, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        // Get the audio buffer list
        var audioBufferList = AudioBufferList()
        var blockBuffer: CMBlockBuffer?
        
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        
        // Get the number of samples
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        
        // Create a PCM buffer
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(numSamples)) else {
            throw NSError(domain: "AudioFileWriter", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not create PCM buffer"])
        }
        
        pcmBuffer.frameLength = AVAudioFrameCount(numSamples)
        
        // Copy the audio data
        let channels = Int(format.channelCount)
        let bufferList = UnsafeMutableAudioBufferListPointer(&audioBufferList)
        
        for channel in 0..<channels {
            if channel < bufferList.count {
                let source = bufferList[channel].mData
                let sourceSize = Int(bufferList[channel].mDataByteSize)
                
                if let destination = pcmBuffer.floatChannelData?[channel] {
                    memcpy(destination, source, sourceSize)
                }
            }
        }
        
        return pcmBuffer
    }
}

// MARK: - Main

AudioCaptureCLI.main()
