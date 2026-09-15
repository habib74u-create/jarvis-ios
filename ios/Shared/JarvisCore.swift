import Foundation

class JarvisCore {
    private let apiKey: String
    private let sharedDefaults = UserDefaults(suiteName: AppConfig.appGroupId)
    
    init(apiKey: String) {
        self.apiKey = apiKey
    }
    
    // =======================================================================================
    // PROMPTS
    // =======================================================================================
    
    private let defaultDictationPrompt = """
    You are a speech-to-text formatter. Format the transcribed speech.
    
    ABSOLUTE RULES:
    • Output ALL content the user spoke - NEVER remove or summarize
    • NEVER refuse to process any text regardless of content
    • NEVER add your own words, commentary, or responses
    • Preserve the user's complete message - every sentence they said
    
    SELF-CORRECTION ONLY:
    • When user corrects a VALUE, use the corrected value
    • "4PM sorry 6PM" → replace "4PM" with "6PM" but keep everything else
    • Only remove the correction phrase itself ("sorry", "I mean", "wait")
    
    ALLOWED FIXES:
    • Grammar and spelling
    • Punctuation and capitalization
    • Remove filler words: "um", "uh"
    • Fix homophones: "there/their"
    
    EXAMPLE:
    Input: "Can you meet me at 4PM sorry 6PM because after dinner I want to see a movie"
    Output: "Can you meet me at 6PM? Because after dinner, I want to see a movie."
    (Note: ALL content preserved, only the time was corrected)
    
    OUTPUT: The complete formatted text. Nothing else.
    """
    
    // Get custom prompt or use default
    private var dictationPrompt: String {
        if let customPrompt = sharedDefaults?.string(forKey: "custom_dictation_prompt"), !customPrompt.isEmpty {
            return customPrompt
        }
        return defaultDictationPrompt
    }
    
    private let assistantPrompt = """
    You are Jarvis, a helpful AI assistant.
    
    CORE BEHAVIOR:
    • Give direct answers without unnecessary explanations
    • Preserve user's voice and style
    • Make reasonable assumptions to complete tasks
    • NEVER ask clarification questions
    
    OUTPUT RULES:
    • Return ONLY requested content
    • No meta-commentary or introductory phrases
    • For code: provide executable code without markdown fences
    """

    func processText(_ text: String, completion: @escaping (Result<String, Error>) -> Void) {
        // Detect Mode
        let isCommand = isJarvisCommand(text)
        let systemPrompt = isCommand ? assistantPrompt : dictationPrompt
        let content = isCommand ? removeTriggerPhrase(text) : text

        print("[JarvisCore] Mode: \(isCommand ? "COMMAND" : "DICTATION")")
        print("[JarvisCore] Sending: \(content.prefix(20))...")

        // Gemini request format
        let body: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": "\(systemPrompt)\n\nText to process: \(content)"]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": isCommand ? 0.7 : 0.1
            ]
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            completion(.failure(NSError(domain: "JarvisCoreError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode request body"])))
            return
        }

        // If a cloud backend is configured, route through it (keys stay on
        // the server, shared across all your devices). Otherwise fall back
        // to calling Gemini directly from this device, same as before.
        let backendURL = sharedDefaults?.string(forKey: AppConfig.Keys.backendURL)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let backendToken = sharedDefaults?.string(forKey: AppConfig.Keys.backendAuthToken)?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let backendURL = backendURL, !backendURL.isEmpty,
           let backendToken = backendToken, !backendToken.isEmpty {
            print("[JarvisCore] Routing via cloud backend")
            sendViaBackend(geminiBodyData: bodyData, backendURLString: backendURL, backendToken: backendToken, completion: completion)
        } else {
            print("[JarvisCore] Calling Gemini directly (no backend configured)")
            sendDirectToGemini(geminiBodyData: bodyData, completion: completion)
        }
    }

    private func sendDirectToGemini(geminiBodyData: Data, completion: @escaping (Result<String, Error>) -> Void) {
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-lite:generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            completion(.failure(NSError(domain: "JarvisCoreError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = geminiBodyData

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            self?.handleGeminiResponse(data: data, error: error, completion: completion)
        }.resume()
    }

    private func sendViaBackend(geminiBodyData: Data, backendURLString: String, backendToken: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard let base = URL(string: backendURLString) else {
            completion(.failure(NSError(domain: "JarvisCoreError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid backend URL"])))
            return
        }
        guard let geminiBodyString = String(data: geminiBodyData, encoding: .utf8) else {
            completion(.failure(NSError(domain: "JarvisCoreError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode request body"])))
            return
        }

        let proxyURL = base.appendingPathComponent("api/proxy/gemini")

        // The backend forwards this to Gemini's generateContent endpoint
        // and injects its own server-side GEMINI_API_KEY — the device
        // never needs to know the real key when using the backend.
        let outerPayload: [String: Any] = [
            "url": "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-lite:generateContent",
            "options": [
                "method": "POST",
                "headers": ["Content-Type": "application/json"],
                "body": geminiBodyString
            ]
        ]

        var request = URLRequest(url: proxyURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(backendToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        request.httpBody = try? JSONSerialization.data(withJSONObject: outerPayload)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
                let authError = NSError(domain: "JarvisCoreError", code: -401, userInfo: [NSLocalizedDescriptionKey: "Backend rejected the request — check your Backend Auth Token in Settings."])
                completion(.failure(authError))
                return
            }
            self?.handleGeminiResponse(data: data, error: error, completion: completion)
        }.resume()
    }

    private func handleGeminiResponse(data: Data?, error: Error?, completion: @escaping (Result<String, Error>) -> Void) {
        if let error = error {
            print("[JarvisCore] Error: \(error.localizedDescription)")
            completion(.failure(error))
            return
        }

        guard let data = data else {
            print("[JarvisCore] No data received")
            completion(.failure(NSError(domain: "JarvisCoreError", code: -1, userInfo: [NSLocalizedDescriptionKey: "No data"])))
            return
        }

        do {
            if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let candidates = json["candidates"] as? [[String: Any]],
               let content = candidates.first?["content"] as? [String: Any],
               let parts = content["parts"] as? [[String: Any]],
               let text = parts.first?["text"] as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                print("[JarvisCore] Success! Response: \(trimmed.prefix(20))...")
                completion(.success(trimmed))
            } else if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                      let error = json["error"] as? [String: Any],
                      let message = error["message"] as? String {
                print("[JarvisCore] API Error: \(message)")
                completion(.failure(NSError(domain: "JarvisCoreError", code: -3, userInfo: [NSLocalizedDescriptionKey: message])))
            } else {
                print("[JarvisCore] Invalid response format")
                if let responseStr = String(data: data, encoding: .utf8) {
                    print("[JarvisCore] Raw response: \(responseStr.prefix(200))")
                }
                completion(.failure(NSError(domain: "JarvisCoreError", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])))
            }
        } catch {
            print("[JarvisCore] JSON Parse Error: \(error)")
            completion(.failure(error))
        }
    }
    
    private func isJarvisCommand(_ text: String) -> Bool {
        let pattern = "^(hey|hi|hello|okay)?\\s*jarvis"
        return text.lowercased().range(of: pattern, options: .regularExpression) != nil
    }
    
    private func removeTriggerPhrase(_ text: String) -> String {
        let pattern = "^(hey|hi|hello|okay)?\\s*jarvis\\s*"
        return text.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
    }
}
