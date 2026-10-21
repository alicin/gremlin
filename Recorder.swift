import Accelerate
import AVFoundation
import ScreenCaptureKit

// Writes a capture to a QuickTime movie in 10 second fragments, so a crash or a power cut loses at most the last few
// seconds: the screen's video, then system audio and the mic on separate tracks.
final class Recorder: NSObject, SCStreamOutput, @unchecked Sendable {
    struct Health {
        var frames = 0
        var micBuffers = 0
        var micPeak: Float = 0
        var soundPeak: Float = 0
        var error: Error?
    }

    let queue = DispatchQueue(label: "com.bunniesinc.gremlin.recorder")
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let sound: AVAssetWriterInput
    private let mic: AVAssetWriterInput
    private let soundAudio = Normalizer(channels: 2)
    private let micAudio = Normalizer(channels: 1)
    private var started = false
    private var finishing = false
    private var last = CMTime.zero
    private var health = Health()

    init(url: URL, width: Int, height: Int) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 5_000_000, AVVideoExpectedSourceFrameRateKey: 15,
                AVVideoMaxKeyFrameIntervalKey: 30, AVVideoAllowFrameReorderingKey: false,
            ],
        ])
        sound = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aac(channels: 2))
        mic = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aac(channels: 1))
        super.init()
        for input in [video, sound, mic] {
            input.expectsMediaDataInRealTime = true
            writer.add(input)
        }
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    private static func aac(channels: Int) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: channels,
         AVEncoderBitRateKey: 64000 * channels]
    }

    // Peaks are since the last call, so each call tells what the last few seconds sounded like.
    func takeHealth() -> Health {
        queue.sync {
            let snapshot = health
            health.micPeak = 0
            health.soundPeak = 0
            return snapshot
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !finishing, buffer.isValid else { return }
        guard writer.status == .writing else {
            if writer.status == .failed, health.error == nil { health.error = writer.error ?? CocoaError(.fileWriteUnknown) }
            return
        }
        switch type {
        case .screen:
            guard Self.isComplete(buffer) else { return }
            if !started {
                writer.startSession(atSourceTime: buffer.presentationTimeStamp)
                started = true
            }
            if video.isReadyForMoreMediaData, video.append(buffer) {
                health.frames += 1
                last = max(last, buffer.presentationTimeStamp)
            }
        case .audio:
            guard started, let converted = soundAudio.convert(buffer) else { return }
            health.soundPeak = max(health.soundPeak, converted.peak)
            if sound.isReadyForMoreMediaData, sound.append(converted.buffer) { last = max(last, converted.end) }
        case .microphone:
            guard started else { return }
            health.micBuffers += 1
            guard let converted = micAudio.convert(buffer) else { return }
            health.micPeak = max(health.micPeak, converted.peak)
            if mic.isReadyForMoreMediaData, mic.append(converted.buffer) { last = max(last, converted.end) }
        @unknown default:
            break
        }
    }

    // ScreenCaptureKit sends status-only buffers while nothing on screen changes.
    private static func isComplete(_ buffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: status) == .complete
        else { return false }
        return CMSampleBufferGetImageBuffer(buffer) != nil
    }

    // Calls back with whether anything was recorded.
    func finish(_ done: @escaping @Sendable (_ recorded: Bool, _ error: Error?) -> Void) {
        queue.async { [self] in
            finishing = true
            guard started else {
                writer.cancelWriting()
                return done(false, nil)
            }
            [video, sound, mic].forEach { $0.markAsFinished() }
            writer.endSession(atSourceTime: last)
            writer.finishWriting { [self] in done(true, writer.status == .completed ? nil : writer.error) }
        }
    }
}

// Converts audio to 48 kHz float with a fixed channel count. The mic's format changes when, say, AirPods connect, and
// an AVAssetWriterInput keeps reading every buffer as the first format it saw, which garbles the rest of the track.
final class Normalizer {
    private let format: AVAudioFormat
    private var converter: AVAudioConverter?
    private var next: CMTime?

    init(channels: AVAudioChannelCount) {
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: channels, interleaved: true)!
    }

    func convert(_ buffer: CMSampleBuffer) -> (buffer: CMSampleBuffer, peak: Float, end: CMTime)? {
        guard let description = buffer.formatDescription, buffer.numSamples > 0 else { return nil }
        let source = AVAudioFormat(cmAudioFormatDescription: description)
        if converter?.inputFormat != source { converter = AVAudioConverter(from: source, to: format) }
        let frames = AVAudioFrameCount(buffer.numSamples)
        guard let converter, let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: frames) else { return nil }
        input.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(buffer, at: 0, frameCount: Int32(frames),
                                                           into: input.mutableAudioBufferList) == noErr else { return nil }
        let capacity = AVAudioFrameCount((Double(frames) * format.sampleRate / source.sampleRate).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, output.frameLength > 0, let samples = output.floatChannelData?[0] else { return nil }

        // Timestamps count samples from where the audio started, so resampling never leaves gaps or overlaps. They
        // only jump ahead when the source skips, e.g. while the mic switches devices.
        let start = buffer.presentationTimeStamp
        if next == nil || start - next! > CMTime(seconds: 0.25, preferredTimescale: 48000) { next = start }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000), presentationTimeStamp: next!,
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                                   formatDescription: format.formatDescription, sampleCount: CMItemCount(output.frameLength),
                                   sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
                                   sampleSizeArray: nil, sampleBufferOut: &sample) == noErr, let sample,
              CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                             flags: 0, bufferList: output.audioBufferList) == noErr
        else { return nil }
        next = next! + CMTime(value: CMTimeValue(output.frameLength), timescale: 48000)
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(output.frameLength * format.channelCount))
        return (sample, peak, next!)
    }
}
