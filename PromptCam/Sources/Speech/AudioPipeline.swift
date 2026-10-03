import AVFoundation

/// 把采集到的音频 sample buffer 转成语音识别要的格式。
///
/// 实测识别引擎只接受 **16kHz / 单声道 / Int16**，而 AVCaptureSession
/// 采下来通常是 44.1k~48kHz 浮点，所以这一层的重采样是必须的。
/// 目标格式运行时向引擎索取（`SpeechAnalyzer.bestAvailableAudioFormat`），不硬编码 ——
/// 换识别语言时它会自动给出对应格式，这里不需要知道当前是哪种语言。
final class AudioPipeline {

    private var converter: AVAudioConverter?
    private var cachedInputFormat: AVAudioFormat?
    private(set) var targetFormat: AVAudioFormat?

    func setTarget(_ format: AVAudioFormat) {
        targetFormat = format
        converter = nil
        cachedInputFormat = nil
    }

    /// 相机路径：音频从 AVCaptureSession 的 audio output 旁路过来
    func convert(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let source = Self.makePCMBuffer(from: sampleBuffer) else { return nil }
        return convert(source)
    }

    /// 麦克风直采路径：`AVAudioEngine` 的 tap 直接给 PCM buffer，
    /// 不用绕 CMSampleBuffer。悬浮提词在后台跟读走这条 ——
    /// 相机 session 一进后台就被系统中断，旁路那条路断了。
    func convert(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let targetFormat else { return nil }

        // 已经是目标格式就直接用，省一次重采样
        if source.format.sampleRate   == targetFormat.sampleRate,
           source.format.channelCount == targetFormat.channelCount,
           source.format.commonFormat == targetFormat.commonFormat {
            return source
        }

        if converter == nil || cachedInputFormat != source.format {
            converter = AVAudioConverter(from: source.format, to: targetFormat)
            converter?.sampleRateConverterQuality = AVAudioQuality.medium.rawValue
            cachedInputFormat = source.format
        }
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                            frameCapacity: capacity) else { return nil }

        var error: NSError?
        var delivered = false
        converter.convert(to: output, error: &error) { _, status in
            // 一次调用只喂一个输入缓冲，喂完就报 noDataNow 结束本轮
            if delivered {
                status.pointee = .noDataNow
                return nil
            }
            delivered = true
            status.pointee = .haveData
            return source
        }

        guard error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    // MARK: -

    private static func makePCMBuffer(from sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
              let format = AVAudioFormat(streamDescription: asbd) else { return nil }

        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sb, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }
}
