import TurboFieldfare

public struct Args: Equatable, Sendable {
    public var model: String
    public var prompt: String?
    public var chatPrompt: String?
    public var messagesFile: String?
    public var images: [String]
    public var visionPack: String?
    public var visionResidency: VisionResidencyPolicy
    public var maxNew: Int
    public var maxContext: Int
    public var temperature: Float
    public var topK: Int?
    public var topP: Float?
    public var repetitionPenalty: Float
    public var seed: UInt64?
    public var stops: [String]
    public var quiet: Bool
    public var progress: Bool
    public var metricsJSON: Bool
    public var expertCacheSlots: Int
    public var expertCachePolicy: RuntimeExpertCachePolicy
    public var prefillPolicy: RuntimePrefillPolicy
    public var prefillChunkTokens: Int
    /// `--prefill-chunk-tokens auto`: the size is decided once the prompt length
    /// is known, which needs the tokenizer and, for images, their geometry.
    public var prefillChunkTokensAuto: Bool
    public var rdadvisePolicy: RDAdvicePolicyMode

    public init(model: String,
                prompt: String? = nil,
                chatPrompt: String? = nil,
                messagesFile: String? = nil,
                images: [String] = [],
                visionPack: String? = nil,
                visionResidency: VisionResidencyPolicy = .defaultPolicy,
                maxNew: Int = 1_024,
                maxContext: Int = 8192,
                temperature: Float = 0.2,
                topK: Int? = 64,
                topP: Float? = 0.95,
                repetitionPenalty: Float = 1.0,
                seed: UInt64? = nil,
                stops: [String] = [],
                quiet: Bool = false,
                progress: Bool = false,
                metricsJSON: Bool = false,
                expertCacheSlots: Int = RuntimeConfiguration.production.expertCacheSlots,
                expertCachePolicy: RuntimeExpertCachePolicy = RuntimeConfiguration.production.expertCachePolicy,
                prefillPolicy: RuntimePrefillPolicy = RuntimeConfiguration.production.prefillPolicy,
                prefillChunkTokens: Int = RuntimeConfiguration.production.prefillChunkTokens,
                prefillChunkTokensAuto: Bool = false,
                rdadvisePolicy: RDAdvicePolicyMode = RuntimeConfiguration.production.rdadvisePolicy) {
        self.model = model
        self.prompt = prompt
        self.chatPrompt = chatPrompt
        self.messagesFile = messagesFile
        self.images = images
        self.visionPack = visionPack
        self.visionResidency = visionResidency
        self.maxNew = maxNew
        self.maxContext = maxContext
        self.temperature = temperature
        self.topK = topK
        self.topP = topP
        self.repetitionPenalty = repetitionPenalty
        self.seed = seed
        self.stops = stops
        self.quiet = quiet
        self.progress = progress
        self.metricsJSON = metricsJSON
        self.expertCacheSlots = expertCacheSlots
        self.expertCachePolicy = expertCachePolicy
        self.prefillPolicy = prefillPolicy
        self.prefillChunkTokens = prefillChunkTokens
        self.prefillChunkTokensAuto = prefillChunkTokensAuto
        self.rdadvisePolicy = rdadvisePolicy
    }
}

public enum ArgsError: Error, Equatable, CustomStringConvertible {
    case helpRequested
    case unknownFlag(String)
    case missingValue(flag: String)
    case invalidValue(flag: String, value: String)
    case requiredMissing(String)
    case mutuallyExclusive(String, String)
    case modeMissing
    case imagePromptNeedsExpertCacheSlots(have: Int, need: Int)

    public var description: String {
        switch self {
        case .helpRequested: return "help requested"
        case .unknownFlag(let flag): return "unknown flag: \(flag)"
        case .missingValue(let flag): return "missing value for \(flag)"
        case .invalidValue(let flag, let value): return "invalid value for \(flag): \(value)"
        case .requiredMissing(let flag): return "required flag missing: \(flag)"
        case .mutuallyExclusive(let a, let b): return "\(a) and \(b) are mutually exclusive"
        case .modeMissing:
            return "one of --prompt, --chat (or --chat-prompt), or --messages-file is required"
        case .imagePromptNeedsExpertCacheSlots(let have, let need):
            return "--image requires chunked prefill, which needs at least \(need) "
                + "expert-cache slots; --expert-cache-slots \(have) cannot serve it: "
                + "raise --expert-cache-slots to \(need) or more, or drop --image"
        }
    }
}

extension Args {
    /// Whether `--prefill-chunk-tokens auto` has a size to resolve at all.
    ///
    /// Under `--prefill off` the config is `.off` and the size is inert, and an
    /// image turn there is coerced to the runtime's own chunked default rather
    /// than to a resolved size, so resolving one would only announce a number
    /// nothing goes on to use.
    public var resolvesPrefillChunkAuto: Bool {
        prefillChunkTokensAuto && prefillPolicy != .off
    }

    public static let usage = """
    TurboFieldfareCLI — Gemma 4 26B-A4B text generation

    usage: TurboFieldfareCLI (--chat <message> | --prompt <string> | --messages-file <path>) [options]
           TurboFieldfareCLI chat <message> [options]
           TurboFieldfareCLI run <raw-prompt> [options]

    input (choose one):
      --chat <message>           Single instruction using Gemma's chat template.
      --chat-prompt <message>    Alias for chat input; required with image input.
      --prompt <string>          Raw-completion prompt.
      --messages-file <path>     JSON chat messages with role and content fields.

    options:
      --model <dir>              Model directory (default scratch/gemma4.gturbo).
      --image <path>             Attach an image; repeatable. Needs chat input.
      --vision-pack <dir>        Companion pack (default beside the model).
      --vision-residency <on-demand|keep-ready>
                                 Routed-expert residency during vision (default on-demand).
      --max-new <int>            Generated-token limit (default 1024).
      --max-context <int>        Context limit in tokens (default 8192).
      --temperature <float>      Sampling temperature (default 0.2; 0 = greedy).
      --top-k <int>              Top-k truncation, 1...256 (default 64; 0 = off).
      --top-p <float>            Nucleus truncation (default 0.95).
      --repetition-penalty <f>   Repetition penalty (default 1.0).
      --seed <uint64>            Deterministic sampling seed (default off).
      --stop <string>            Stop substring (repeatable).
      --quiet                    Suppress the timing footer.
      --progress                 Report tokenizer, model-load, and prefill progress to stderr.
      --metrics-json             Emit the final timing footer as JSON on stderr.
      --expert-cache-slots <n>   Expert-cache slots: \(RuntimeConfiguration.allowedValueList(RuntimeConfiguration.allowedExpertCacheSlots)) (default 16).
      --expert-cache-policy <s>  Expert-cache policy: lfu or lru (default lfu).
      --prefill on|off           Enable or disable chunked prompt prefill (default on).
                                 Chunked prefill requires 16 or more cache slots.
      --prefill-chunk-tokens <n|auto>
                                 Prefill chunk size: \(RuntimeConfiguration.allowedValueList(RuntimeConfiguration.allowedPrefillChunkTokens, alsoAccepting: ["auto"]))
                                 (default 128). Each chunk re-reads the routed
                                 expert pool, so larger chunks read less; auto
                                 picks the smallest size that covers the prompt.
      --rdadvise <s>             Read-advice policy: off, default, bounded, or adaptive (default off).
      --help                     Show this message.
    """

    public func resolvedRuntimeConfiguration(
        forceLogitsHead: Bool,
        imagePrompt: Bool = false) throws -> RuntimeConfiguration {
        // Images reach the runtime two ways, `--image` and `image_file` parts
        // inside `--messages-file`, and only the first fills `images`. Asking
        // the caller keeps the second from surviving validation and dying in
        // the routed tile scheduler after the model load and every GPU encode.
        guard !imagePrompt
                || expertCacheSlots
                >= RuntimeConfiguration.minimumExpertCacheSlotsForChunkedPrefill else {
            throw ArgsError.imagePromptNeedsExpertCacheSlots(
                have: expertCacheSlots,
                need: RuntimeConfiguration.minimumExpertCacheSlotsForChunkedPrefill)
        }
        guard RuntimeConfiguration.allowedExpertCacheSlots.contains(expertCacheSlots) else {
            throw ArgsError.invalidValue(
                flag: "--expert-cache-slots", value: "\(expertCacheSlots)")
        }
        guard RuntimeConfiguration.allowedPrefillChunkTokens.contains(prefillChunkTokens) else {
            throw ArgsError.invalidValue(
                flag: "--prefill-chunk-tokens", value: "\(prefillChunkTokens)")
        }
        let chunkedPrefillSupported = expertCacheSlots >=
            RuntimeConfiguration.minimumExpertCacheSlotsForChunkedPrefill
        guard prefillPolicy == .off || chunkedPrefillSupported else {
            throw ArgsError.invalidValue(
                flag: "--expert-cache-slots",
                value: "\(expertCacheSlots) requires --prefill off")
        }
        return RuntimeConfiguration(
            expertCacheSlots: expertCacheSlots,
            expertCachePolicy: expertCachePolicy,
            rdadvisePolicy: rdadvisePolicy,
            prefillEnabled: prefillPolicy == .chunked,
            prefillChunkTokens: prefillChunkTokens,
            forceLogitsHead: forceLogitsHead)
    }

    public static func parse(_ argv: [String]) throws -> Args {
        var input = argv
        var positionalPrompt: String?
        var positionalChatPrompt: String?
        if let command = input.first, command == "chat" || command == "run" {
            guard input.count >= 2 else {
                throw ArgsError.missingValue(flag: command)
            }
            let value = input[1]
            if command == "chat" {
                positionalChatPrompt = value
            } else {
                positionalPrompt = value
            }
            input.removeFirst(2)
        }
        var model = "scratch/gemma4.gturbo"
        var prompt: String? = positionalPrompt
        var chatPrompt: String? = positionalChatPrompt
        var messagesFile: String?
        var images: [String] = []
        var visionPack: String?
        var visionResidency: VisionResidencyPolicy = .defaultPolicy
        var maxNew = 1_024
        var maxContext = 8192
        var temperature: Float = 0.2
        var topK: Int? = 64
        var topP: Float? = 0.95
        var repetitionPenalty: Float = 1.0
        var seed: UInt64?
        var stops: [String] = []
        var quiet = false
        var progress = false
        var metricsJSON = false
        let runtimeDefaults = RuntimeConfiguration.production
        var expertCacheSlots = runtimeDefaults.expertCacheSlots
        var expertCachePolicy = runtimeDefaults.expertCachePolicy
        var prefillPolicy = runtimeDefaults.prefillPolicy
        var prefillChunkTokens = runtimeDefaults.prefillChunkTokens
        var prefillChunkTokensAuto = false
        var rdadvisePolicy = runtimeDefaults.rdadvisePolicy

        var index = 0
        while index < input.count {
            let flag = input[index]
            switch flag {
            case "--help", "-h":
                throw ArgsError.helpRequested
            case "--quiet":
                quiet = true
                index += 1
            case "--progress":
                progress = true
                index += 1
            case "--metrics-json":
                metricsJSON = true
                index += 1
            case "--model":
                model = try takeValue(input, &index, flag: flag)
            case "--prompt":
                prompt = try takeValue(input, &index, flag: flag)
            case "--chat", "--chat-prompt":
                chatPrompt = try takeValue(input, &index, flag: flag)
            case "--image":
                images.append(try takeValue(input, &index, flag: flag))
            case "--vision-pack":
                visionPack = try takeValue(input, &index, flag: flag)
            case "--vision-residency":
                let value = try takeValue(input, &index, flag: flag)
                guard let policy = VisionResidencyPolicy(rawValue: value) else {
                    throw ArgsError.invalidValue(flag: flag, value: value)
                }
                visionResidency = policy
            case "--messages-file":
                messagesFile = try takeValue(input, &index, flag: flag)
            case "--max-new":
                let value = try takeValue(input, &index, flag: flag)
                guard let parsed = Int(value), parsed > 0 else {
                    throw ArgsError.invalidValue(flag: flag, value: value)
                }
                maxNew = parsed
            case "--max-context":
                let value = try takeValue(input, &index, flag: flag)
                guard let parsed = Int(value), parsed > 0 else {
                    throw ArgsError.invalidValue(flag: flag, value: value)
                }
                maxContext = parsed
            case "--temperature":
                let value = try takeValue(input, &index, flag: flag)
                guard let parsed = Float(value), parsed >= 0 else {
                    throw ArgsError.invalidValue(flag: flag, value: value)
                }
                temperature = parsed
            case "--top-k":
                let value = try takeValue(input, &index, flag: flag)
                guard let parsed = Int(value), (0...256).contains(parsed) else {
                    throw ArgsError.invalidValue(flag: flag, value: value)
                }
                topK = parsed == 0 ? nil : parsed
            case "--top-p":
                let value = try takeValue(input, &index, flag: flag)
                guard let parsed = Float(value), parsed > 0, parsed <= 1 else {
                    throw ArgsError.invalidValue(flag: flag, value: value)
                }
                topP = parsed
            case "--repetition-penalty":
                let value = try takeValue(input, &index, flag: flag)
                guard let parsed = Float(value), parsed > 0 else {
                    throw ArgsError.invalidValue(flag: flag, value: value)
                }
                repetitionPenalty = parsed
            case "--seed":
                let value = try takeValue(input, &index, flag: flag)
                guard let parsed = UInt64(value) else {
                    throw ArgsError.invalidValue(flag: flag, value: value)
                }
                seed = parsed
            case "--stop":
                stops.append(try takeValue(input, &index, flag: flag))
            case "--expert-cache-slots":
                let value = try takeValue(input, &index, flag: flag)
                guard let parsed = Int(value),
                      RuntimeConfiguration.allowedExpertCacheSlots.contains(parsed) else {
                    throw ArgsError.invalidValue(flag: flag, value: value)
                }
                expertCacheSlots = parsed
            case "--expert-cache-policy":
                let value = try takeValue(input, &index, flag: flag)
                guard let parsed = RuntimeExpertCachePolicy(rawValue: value) else {
                    throw ArgsError.invalidValue(flag: flag, value: value)
                }
                expertCachePolicy = parsed
            case "--prefill":
                let value = try takeValue(input, &index, flag: flag)
                switch value {
                case "on": prefillPolicy = .chunked
                case "off": prefillPolicy = .off
                default: throw ArgsError.invalidValue(flag: flag, value: value)
                }
            case "--prefill-chunk-tokens":
                let value = try takeValue(input, &index, flag: flag)
                if value == "auto" {
                    prefillChunkTokensAuto = true
                    break
                }
                guard let parsed = Int(value),
                      RuntimeConfiguration.allowedPrefillChunkTokens.contains(parsed) else {
                    throw ArgsError.invalidValue(flag: flag, value: value)
                }
                // A repeated flag is last-one-wins in both directions: without
                // this clear, an explicit size after `auto` parses and is then
                // overridden at run time by the resolved size.
                prefillChunkTokensAuto = false
                prefillChunkTokens = parsed
            case "--rdadvise":
                let value = try takeValue(input, &index, flag: flag)
                guard let parsed = RDAdvicePolicyMode(rawValue: value) else {
                    throw ArgsError.invalidValue(flag: flag, value: value)
                }
                rdadvisePolicy = parsed
            default:
                throw ArgsError.unknownFlag(flag)
            }
        }

        if prompt != nil, chatPrompt != nil {
            throw ArgsError.mutuallyExclusive("--prompt", "--chat")
        }
        if prompt != nil, messagesFile != nil {
            throw ArgsError.mutuallyExclusive("--prompt", "--messages-file")
        }
        if messagesFile != nil, chatPrompt != nil {
            throw ArgsError.mutuallyExclusive("--chat", "--messages-file")
        }
        if prompt != nil, !images.isEmpty {
            throw ArgsError.mutuallyExclusive("--prompt", "--image")
        }
        let minimumSlots = RuntimeConfiguration.minimumExpertCacheSlotsForChunkedPrefill
        if !images.isEmpty, expertCacheSlots < minimumSlots {
            throw ArgsError.imagePromptNeedsExpertCacheSlots(
                have: expertCacheSlots, need: minimumSlots)
        }
        if !images.isEmpty, chatPrompt == nil {
            // Naming the flag the user actually left out. Reporting a conflict
            // with `--messages-file` sent them looking for a flag they never
            // passed, in the most likely first-run mistake there is.
            throw messagesFile == nil
                ? ArgsError.requiredMissing("--chat-prompt")
                : ArgsError.mutuallyExclusive("--image", "--messages-file")
        }
        if prompt == nil && chatPrompt == nil && messagesFile == nil {
            throw ArgsError.modeMissing
        }
        if temperature > 0, topK == nil, let topP, topP < 1 {
            throw ArgsError.invalidValue(
                flag: "--top-p",
                value: "\(topP) requires --top-k between 1 and 256")
        }
        let arguments = Args(model: model,
                             prompt: prompt,
                             chatPrompt: chatPrompt,
                             messagesFile: messagesFile,
                             images: images,
                             visionPack: visionPack,
                             visionResidency: visionResidency,
                             maxNew: maxNew,
                             maxContext: maxContext,
                             temperature: temperature,
                             topK: topK,
                             topP: topP,
                             repetitionPenalty: repetitionPenalty,
                             seed: seed,
                             stops: stops,
                             quiet: quiet,
                             progress: progress,
                             metricsJSON: metricsJSON,
                             expertCacheSlots: expertCacheSlots,
                             expertCachePolicy: expertCachePolicy,
                             prefillPolicy: prefillPolicy,
                             prefillChunkTokens: prefillChunkTokens,
                             prefillChunkTokensAuto: prefillChunkTokensAuto,
                             rdadvisePolicy: rdadvisePolicy)
        _ = try arguments.resolvedRuntimeConfiguration(forceLogitsHead: false)
        return arguments
    }

    private static func takeValue(_ argv: [String],
                                  _ index: inout Int,
                                  flag: String) throws -> String {
        guard index + 1 < argv.count else { throw ArgsError.missingValue(flag: flag) }
        let value = argv[index + 1]
        index += 2
        return value
    }
}
