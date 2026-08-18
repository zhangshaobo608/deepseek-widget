// DeepSeek 浮窗 —— 展示当天 V4 Flash / Pro 每百万 token 平均费用与缓存命中率
// 数据源：platform.deepseek.com 平台内部用量接口（userToken Bearer 鉴权）
// 构建：./build.sh

import AppKit
import Foundation

// MARK: - 定价参考（元/百万 tokens，2026-08-17 生效；峰时=北京时间 9:00-12:00 / 14:00-18:00）

struct PriceRef {
    let name: String
    let peakHit: Double, peakMiss: Double, peakOut: Double
    let offHit: Double, offMiss: Double, offOut: Double

    var tooltip: String {
        let f: (Double) -> String = { v in
            v == v.rounded() ? String(format: "%.0f", v) : String(format: "%.2f", v)
        }
        return "\(name) 参考价（元/百万 tokens）\n"
            + "峰时：输入命中 \(f(peakHit)) · 未命中 \(f(peakMiss)) · 输出 \(f(peakOut))\n"
            + "闲时：输入命中 \(f(offHit)) · 未命中 \(f(offMiss)) · 输出 \(f(offOut))\n"
            + "平均费用 = 今日成本 ÷ 今日 token 数 × 100 万"
    }
}

let flashRef = PriceRef(name: "DeepSeek-V4-Flash",
                        peakHit: 0.10, peakMiss: 3.00, peakOut: 9.00,
                        offHit: 0.05, offMiss: 1.50, offOut: 4.50)
let proRef = PriceRef(name: "DeepSeek-V4-Pro",
                      peakHit: 0.30, peakMiss: 9.00, peakOut: 27.00,
                      offHit: 0.15, offMiss: 4.50, offOut: 13.50)

func isBeijingPeak(_ date: Date = Date()) -> Bool {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
    let c = cal.dateComponents([.hour, .minute], from: date)
    let t = (c.hour ?? 0) * 60 + (c.minute ?? 0)
    return (t >= 9 * 60 && t < 12 * 60) || (t >= 14 * 60 && t < 18 * 60)
}

// MARK: - 数据模型

enum ModelKind { case flash, pro, other }

func classify(_ model: String) -> ModelKind {
    let m = model.lowercased()
    if m.contains("flash") { return .flash }
    if m.contains("pro") { return .pro }
    return .other
}

struct Agg {
    var hit: Int64 = 0
    var miss: Int64 = 0
    var out: Int64 = 0
    var req: Int64 = 0
    var cost: [String: Double] = [:]

    var tokens: Int64 { hit + miss + out }
    var hitRate: Double? { hit + miss > 0 ? Double(hit) / Double(hit + miss) : nil }

    var primaryCurrency: String {
        cost.keys.contains("CNY") ? "CNY" : (cost.keys.sorted().first ?? "CNY")
    }
    var primaryCost: Double { cost[primaryCurrency] ?? 0 }
    var avgPer1M: Double? { tokens > 0 ? primaryCost / Double(tokens) * 1_000_000 : nil }

    mutating func add(hit: Int64, miss: Int64, out: Int64, req: Int64) {
        self.hit += hit; self.miss += miss; self.out += out; self.req += req
    }
    mutating func addCost(_ c: Double, currency: String) {
        cost[currency, default: 0] += c
    }
}

struct DayReport {
    var flash = Agg()
    var pro = Agg()
    var other = Agg()
    var balance: Double?
    var balanceCurrency: String?

    static func parse(amount: Any?, cost: Any?, summary: Any?) -> DayReport {
        var r = DayReport()
        if let bd = amount as? [String: Any], let series = bd["series"] as? [[String: Any]] {
            for s in series {
                let k = classify(s["model"] as? String ?? "")
                var hit: Int64 = 0, miss: Int64 = 0, out: Int64 = 0, req: Int64 = 0
                for b in (s["buckets"] as? [[String: Any]]) ?? [] {
                    let u = b["usage"] as? [String: Any] ?? [:]
                    hit += Int64(dnum(u["PROMPT_CACHE_HIT_TOKEN"]))
                    miss += Int64(dnum(u["PROMPT_CACHE_MISS_TOKEN"]))
                    out += Int64(dnum(u["RESPONSE_TOKEN"]))
                    req += Int64(dnum(u["REQUEST"]))
                }
                switch k {
                case .flash: r.flash.add(hit: hit, miss: miss, out: out, req: req)
                case .pro: r.pro.add(hit: hit, miss: miss, out: out, req: req)
                case .other: r.other.add(hit: hit, miss: miss, out: out, req: req)
                }
            }
        }
        if let bd = cost as? [String: Any], let entries = bd["data"] as? [[String: Any]] {
            for entry in entries {
                let currency = entry["currency"] as? String ?? "CNY"
                for s in (entry["series"] as? [[String: Any]]) ?? [] {
                    let k = classify(s["model"] as? String ?? "")
                    var c: Double = 0
                    for b in (s["buckets"] as? [[String: Any]]) ?? [] { c += dnum(b["cost"]) }
                    switch k {
                    case .flash: r.flash.addCost(c, currency: currency)
                    case .pro: r.pro.addCost(c, currency: currency)
                    case .other: r.other.addCost(c, currency: currency)
                    }
                }
            }
        }
        if let bd = summary as? [String: Any] {
            var bal: [String: Double] = [:]
            for w in (bd["normal_wallets"] as? [[String: Any]]) ?? [] {
                bal[w["currency"] as? String ?? "CNY", default: 0] += dnum(w["balance"])
            }
            for w in (bd["bonus_wallets"] as? [[String: Any]]) ?? [] {
                bal[w["currency"] as? String ?? "CNY", default: 0] += dnum(w["balance"])
            }
            if !bal.isEmpty {
                let cur = bal.keys.contains("CNY") ? "CNY" : (bal.keys.sorted().first ?? "CNY")
                r.balance = bal[cur]
                r.balanceCurrency = cur
            }
        }
        return r
    }
}

func dnum(_ v: Any?) -> Double {
    guard let v else { return 0 }
    if let n = v as? NSNumber { return n.doubleValue }
    if let s = v as? String, let d = Double(s) { return d }
    return 0
}

func currencySymbol(_ c: String) -> String {
    switch c.uppercased() {
    case "CNY": return "¥"
    case "USD": return "$"
    case "EUR": return "€"
    default: return c
    }
}

func fmtTokens(_ v: Int64) -> String {
    let d = Double(v)
    if d >= 1e9 { return String(format: "%.2fB", d / 1e9) }
    if d >= 1e6 { return String(format: "%.2fM", d / 1e6) }
    if d >= 1e3 { return String(format: "%.1fK", d / 1e3) }
    return "\(v)"
}

func fmtCost(_ v: Double) -> String {
    if v > 0 && v < 0.005 { return "<0.01" }
    return String(format: "%.2f", v)
}

// MARK: - 网络

enum FetchError: LocalizedError {
    case auth(String), api(String), network(String), parse(String)

    var errorDescription: String? {
        switch self {
        case .auth(let m): return "Token 无效或已过期：\(m)"
        case .api(let m): return "接口错误：\(m)"
        case .network(let m): return "网络错误：\(m)"
        case .parse(let m): return "数据解析失败：\(m)"
        }
    }
}

final class DeepSeekFetcher {
    static let base = URL(string: "https://platform.deepseek.com/api/v0")!
    let token: String

    init(token: String) { self.token = token }

    func request(_ path: String, _ params: [String: String],
                 completion: @escaping (Result<Any, FetchError>) -> Void) {
        var comps = URLComponents(url: DeepSeekFetcher.base.appendingPathComponent(path),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 20
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("1.0.0", forHTTPHeaderField: "x-app-version")
        req.setValue("https://platform.deepseek.com", forHTTPHeaderField: "Origin")
        req.setValue("https://platform.deepseek.com/usage", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36",
                     forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: req) { data, _, err in
            if let err {
                completion(.failure(.network(err.localizedDescription)))
                return
            }
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) else {
                completion(.failure(.parse("非 JSON 响应")))
                return
            }
            guard let root = obj as? [String: Any] else {
                completion(.failure(.parse("响应结构异常")))
                return
            }
            if let code = root["code"] as? Int, code != 0 {
                let msg = root["msg"] as? String ?? root["message"] as? String ?? "code \(code)"
                if code == 40002 || code == 40003 { completion(.failure(.auth(msg))) }
                else { completion(.failure(.api(msg))) }
                return
            }
            guard let dataObj = root["data"] as? [String: Any] else {
                completion(.failure(.parse("缺少 data")))
                return
            }
            if let bc = dataObj["biz_code"] as? Int, bc != 0 {
                completion(.failure(.api(dataObj["biz_msg"] as? String ?? "biz_code \(bc)")))
                return
            }
            guard let bd = dataObj["biz_data"] else {
                completion(.failure(.parse("缺少 biz_data")))
                return
            }
            completion(.success(bd))
        }.resume()
    }

    func fetchToday(completion: @escaping (Result<DayReport, FetchError>) -> Void) {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let startSec = Int(start.timeIntervalSince1970)
        // 平台前端按"完整一天"请求（end = 当天0点 + 86400），并对非整小时时区做归一化
        let endSec = startSec + 86400
        let tz = TimeZone.current.secondsFromGMT(for: start)
        let r = Int((Double(tz) / 3600.0).rounded(.down)) * 3600
        let a = tz - r
        let params = [
            "start": "\(startSec + a)",
            "end": "\(endSec + a)",
            "tz": "\(r)",
        ]
        request("/usage/by_api_key/amount", params) { amt in
            self.request("/usage/by_api_key/cost", params) { cost in
                self.request("/users/get_user_summary", [:]) { sum in
                    var failures: [FetchError] = []
                    if case .failure(let e) = amt { failures.append(e) }
                    if case .failure(let e) = cost { failures.append(e) }
                    if case .failure(let e) = sum { failures.append(e) }
                    if failures.count == 3 {
                        let authFirst = failures.first {
                            if case .auth = $0 { return true }
                            return false
                        }
                        completion(.failure(authFirst ?? failures[0]))
                        return
                    }
                    let report = DayReport.parse(
                        amount: (try? amt.get()) ?? nil,
                        cost: (try? cost.get()) ?? nil,
                        summary: (try? sum.get()) ?? nil)
                    completion(.success(report))
                }
            }
        }
    }
}

// MARK: - Chrome userToken 自动导入（扫描 Local Storage leveldb）

func chromeToken() -> String? {
    let browsers = ["Google/Chrome", "Microsoft Edge", "BraveSoftware/Brave-Browser"]
    let fm = FileManager.default
    let home = NSHomeDirectory()
    for b in browsers {
        let base = "\(home)/Library/Application Support/\(b)"
        var profiles = ["Default"]
        if let entries = try? fm.contentsOfDirectory(atPath: base) {
            profiles += entries.filter { $0.hasPrefix("Profile") }.sorted()
        }
        for p in profiles {
            let ldb = "\(base)/\(p)/Local Storage/leveldb"
            guard let files = try? fm.contentsOfDirectory(atPath: ldb) else { continue }
            for f in files.sorted() where f.hasSuffix(".ldb") || f.hasSuffix(".log") {
                if let t = extractToken(from: URL(fileURLWithPath: ldb).appendingPathComponent(f)) {
                    return t
                }
            }
        }
    }
    return nil
}

func extractToken(from url: URL) -> String? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    let bytes = [UInt8](data)
    let markers: [[UInt8]] = [Array("userToken".utf8), Array("settingsJwt".utf8)]
    for marker in markers {
        guard bytes.count > marker.count else { continue }
        var i = 0
        while i <= bytes.count - marker.count {
            if bytes[i] == marker[0] && Array(bytes[i..<i + marker.count]) == marker {
                let start = i + marker.count
                let len = min(16384, bytes.count - start)
                let chunk = Data(bytes[start..<start + len])
                if let t = parseStoredToken(chunk) { return t }
            }
            i += 1
        }
    }
    return nil
}

// 解析 localStorage 键之后跟着的 value（可能是 UTF-16LE JSON 或纯 ASCII JWT）
func parseStoredToken(_ chunk: Data) -> String? {
    func extractFrom(_ str: String) -> String? {
        if let regex = try? NSRegularExpression(pattern: #""value"\s*:\s*"([^"]+)""#) {
            let ns = str as NSString
            if let m = regex.firstMatch(in: str, range: NSRange(location: 0, length: ns.length)),
               let r = Range(m.range(at: 1), in: str) {
                return String(str[r])
            }
        }
        return nil
    }
    var candidates: [String] = []
    if let s = String(data: chunk, encoding: .utf16LittleEndian), let t = extractFrom(s) {
        candidates.append(t)
    }
    if let s = String(data: chunk, encoding: .ascii) {
        if let t = extractFrom(s) { candidates.append(t) }
        // 裸 JWT 兜底
        if let regex = try? NSRegularExpression(pattern: #"eyJ[A-Za-z0-9._\-]{20,}\.[A-Za-z0-9._\-]{20,}\.[A-Za-z0-9._\-]{10,}"#) {
            let ns = s as NSString
            if let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) {
                candidates.append(ns.substring(with: m.range))
            }
        }
    }
    for t in candidates where t.count >= 20
        && t.range(of: #"^[A-Za-z0-9._\-]+$"#, options: .regularExpression) != nil {
        return t
    }
    return nil
}

// MARK: - 颜色与字体

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: r, green: g, blue: b, alpha: a)
}

let cFlash = color(0.30, 0.82, 0.87)
let cPro = color(0.72, 0.53, 1.00)
let cOther = color(0.62, 0.68, 0.75)
let cGreen = color(0.24, 0.78, 0.40)
let cYellow = color(0.95, 0.77, 0.06)
let cRed = color(0.96, 0.36, 0.30)
let cPeak = color(1.00, 0.59, 0.14)
let cOff = color(0.35, 0.80, 0.85)

// 显式文本色（不依赖系统外观解析，保证始终清晰）
let tPrimary = NSColor(calibratedWhite: 1.0, alpha: 1.0)
let tSecondary = NSColor(calibratedWhite: 0.78, alpha: 1.0)
let tTertiary = NSColor(calibratedWhite: 0.56, alpha: 1.0)

func hitColor(_ rate: Double) -> NSColor {
    if rate >= 0.8 { return cGreen }
    if rate >= 0.5 { return cYellow }
    return cRed
}

// MARK: - 基础视图

class BaseView: NSView {
    var onRightClick: ((NSEvent) -> Void)?
    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(event) ?? super.rightMouseDown(with: event)
    }
}

func drawText(_ str: String, at point: NSPoint, font: NSFont, color: NSColor) {
    (str as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
}

func drawRight(_ str: String, atY y: CGFloat, font: NSFont, color: NSColor, maxX: CGFloat) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let size = (str as NSString).size(withAttributes: attrs)
    (str as NSString).draw(at: NSPoint(x: maxX - size.width, y: y), withAttributes: attrs)
}

// MARK: - 头部视图

enum WidgetStatus {
    case noToken, loading, ok, error(String)
}

final class HeaderView: BaseView {
    var status: WidgetStatus = .noToken
    var updatedAt: Date?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawText("DeepSeek 用量", at: NSPoint(x: 12, y: 20), font: .systemFont(ofSize: 14, weight: .semibold), color: tPrimary)
        let peak = isBeijingPeak()
        let tag = peak ? "峰时" : "闲时"
        let tagColor = peak ? cPeak : cOff
        let sub = "今日 · \(tag)"
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .semibold)]
        let titleW = ("DeepSeek 用量" as NSString).size(withAttributes: titleAttrs).width
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: tagColor]
        (sub as NSString).draw(at: NSPoint(x: 12 + titleW + 8, y: 22), withAttributes: attrs)

        // 右侧：更新时间和状态点
        if let updatedAt {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            drawRight("更新 \(f.string(from: updatedAt))", atY: 20, font: .systemFont(ofSize: 10.5), color: tTertiary, maxX: bounds.width - 24)
        }
        let dotColor: NSColor
        switch status {
        case .noToken: dotColor = cOther
        case .loading: dotColor = cPeak
        case .ok: dotColor = cGreen
        case .error: dotColor = cRed
        }
        dotColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: bounds.width - 19, y: 18, width: 8, height: 8)).fill()
    }
}

// MARK: - 模型卡片

final class CardView: BaseView {
    var kind: ModelKind = .flash
    var agg: Agg?

    var accentColor: NSColor {
        switch kind {
        case .flash: return cFlash
        case .pro: return cPro
        case .other: return cOther
        }
    }

    var title: String {
        switch kind {
        case .flash: return "DeepSeek-V4-Flash"
        case .pro: return "DeepSeek-V4-Pro"
        case .other: return "其他模型"
        }
    }

    var priceRef: PriceRef? {
        switch kind {
        case .flash: return flashRef
        case .pro: return proRef
        case .other: return nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 10, yRadius: 10)
        NSColor(calibratedWhite: 1.0, alpha: 0.06).setFill()
        bg.fill()

        // ── 第一行：模型名（左） + 每百万平均费用（右）
        accentColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: 12, y: bounds.height - 30, width: 8, height: 8)).fill()
        drawText(title, at: NSPoint(x: 26, y: bounds.height - 24),
                 font: .systemFont(ofSize: 13, weight: .semibold), color: tPrimary)

        if let a = agg, let avg = a.avgPer1M {
            let sym = currencySymbol(a.primaryCurrency)
            let big = "\(sym)\(String(format: "%.2f", avg))"
            let suffix = "/1M 平均"
            let suffixAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: tPrimary]
            let suffixSize = (suffix as NSString).size(withAttributes: suffixAttrs)
            (suffix as NSString).draw(at: NSPoint(x: bounds.width - 12 - suffixSize.width, y: bounds.height - 27), withAttributes: suffixAttrs)
            let bigAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 18, weight: .bold), .foregroundColor: tPrimary]
            let bigSize = (big as NSString).size(withAttributes: bigAttrs)
            (big as NSString).draw(at: NSPoint(x: bounds.width - 12 - suffixSize.width - 6 - bigSize.width, y: bounds.height - 28), withAttributes: bigAttrs)
        } else {
            drawRight("—", atY: bounds.height - 28, font: .monospacedDigitSystemFont(ofSize: 18, weight: .bold), color: tTertiary, maxX: bounds.width - 12)
        }

        // ── 第二行：今日消耗（白色半粗体为焦点）+ tokens + 请求
        if let a = agg, a.tokens > 0 {
            let sym = currencySymbol(a.primaryCurrency)
            let baseY = bounds.height - 46
            let grayAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: tSecondary]
            let valAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: tPrimary]
            let label = "今日"
            (label as NSString).draw(at: NSPoint(x: 12, y: baseY), withAttributes: grayAttrs)
            let labelW = (label as NSString).size(withAttributes: grayAttrs).width
            let val = "\(sym)\(fmtCost(a.primaryCost))"
            (val as NSString).draw(at: NSPoint(x: 12 + labelW + 6, y: baseY), withAttributes: valAttrs)
            let valW = (val as NSString).size(withAttributes: valAttrs).width
            let rest = " · \(fmtTokens(a.tokens)) tokens · \(a.req) 请求"
            (rest as NSString).draw(at: NSPoint(x: 12 + labelW + 6 + valW + 4, y: baseY), withAttributes: grayAttrs)
        } else {
            drawText("今日暂无用量", at: NSPoint(x: 12, y: bounds.height - 46), font: .systemFont(ofSize: 10.5), color: tTertiary)
        }

        // ── 第三行：命中率文字 + 全宽进度条（独立成行，与上下内容拉开间距）
        if let a = agg, let rate = a.hitRate {
            let hc = hitColor(rate)
            drawText(String(format: "命中率 %.1f%%", rate * 100), at: NSPoint(x: 12, y: 22),
                     font: .monospacedDigitSystemFont(ofSize: 11, weight: .medium), color: hc)
            let barW = bounds.width - 24
            let track = NSRect(x: 12, y: 6, width: barW, height: 5)
            NSColor(calibratedWhite: 1.0, alpha: 0.14).setFill()
            NSBezierPath(roundedRect: track, xRadius: 2.5, yRadius: 2.5).fill()
            let fillW = max(6, barW * CGFloat(min(max(rate, 0), 1)))
            hc.setFill()
            NSBezierPath(roundedRect: NSRect(x: 12, y: 6, width: fillW, height: 5), xRadius: 2.5, yRadius: 2.5).fill()
        }
    }
}

// MARK: - 底部视图

final class FooterView: BaseView {
    var report: DayReport?
    var status: WidgetStatus = .noToken

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        switch status {
        case .noToken:
            drawText("右键 → 设置 Token（可自动从 Chrome 读取）",
                     at: NSPoint(x: 12, y: 12), font: .systemFont(ofSize: 11), color: tTertiary)
        case .error(let msg):
            drawText("⚠ \(msg)", at: NSPoint(x: 12, y: 12), font: .systemFont(ofSize: 11), color: cRed)
        case .loading, .ok:
            var parts: [String] = []
            if let r = report {
                let cur = r.flash.primaryCurrency
                let totalCost = r.flash.primaryCost + r.pro.primaryCost + r.other.primaryCost
                if totalCost > 0 {
                    parts.append("今日总成本 \(currencySymbol(cur))\(fmtCost(totalCost))")
                } else {
                    parts.append("今日总成本 ¥0.00")
                }
                let allHit = r.flash.hit + r.pro.hit + r.other.hit
                let allMiss = r.flash.miss + r.pro.miss + r.other.miss
                if allHit + allMiss > 0 {
                    parts.append(String(format: "总命中率 %.1f%%", Double(allHit) / Double(allHit + allMiss) * 100))
                }
                if let bal = r.balance {
                    parts.append(String(format: "余额 %@%.2f", currencySymbol(r.balanceCurrency ?? cur), bal))
                }
            }
            if parts.isEmpty {
                drawText("正在加载…", at: NSPoint(x: 12, y: 12), font: .systemFont(ofSize: 11), color: tTertiary)
            } else {
                drawText(parts.joined(separator: " · "), at: NSPoint(x: 12, y: 12), font: .systemFont(ofSize: 11), color: tSecondary)
            }
        }
    }
}

// MARK: - 设置窗口

final class SettingsController: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let tokenField = NSSecureTextField()
    private let statusLabel = NSTextField(labelWithString: "")
    var onChanged: (() -> Void)?
    private let tokenKey = "dsUserToken"

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 316),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "DeepSeek 浮窗 · 设置"
        window.delegate = self
        window.isReleasedWhenClosed = false

        let content = window.contentView!
        let title = NSTextField(labelWithString: "配置 DeepSeek 开放平台 userToken（本机保存，不联网上传）")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.frame = NSRect(x: 20, y: 272, width: 430, height: 20)
        content.addSubview(title)

        let instructions = """
        获取方式（任选其一）：
        1. 在 Chrome 登录 platform.deepseek.com → 按 F12 打开开发者工具 → Console 粘贴执行：
           JSON.parse(localStorage.getItem('userToken')).value
           复制输出（以 eyJ 开头的长串）粘贴到下方。
        2. 点击下方“从 Chrome 读取”，自动从本机 Chrome / Edge / Brave 导入（免登录复制）。
        """
        let instr = NSTextField(wrappingLabelWithString: instructions)
        instr.font = .systemFont(ofSize: 11)
        instr.textColor = .secondaryLabelColor
        instr.frame = NSRect(x: 20, y: 148, width: 430, height: 116)
        content.addSubview(instr)

        tokenField.placeholderString = "粘贴 userToken（以 eyJ 开头）"
        tokenField.frame = NSRect(x: 20, y: 112, width: 430, height: 24)
        tokenField.stringValue = UserDefaults.standard.string(forKey: tokenKey) ?? ""
        content.addSubview(tokenField)

        let saveBtn = NSButton(title: "保存并刷新", target: self, action: #selector(save))
        saveBtn.frame = NSRect(x: 20, y: 72, width: 110, height: 28)
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        content.addSubview(saveBtn)

        let chromeBtn = NSButton(title: "从 Chrome 读取", target: self, action: #selector(importChrome))
        chromeBtn.frame = NSRect(x: 138, y: 72, width: 120, height: 28)
        chromeBtn.bezelStyle = .rounded
        content.addSubview(chromeBtn)

        let testBtn = NSButton(title: "测试", target: self, action: #selector(test))
        testBtn.frame = NSRect(x: 266, y: 72, width: 80, height: 28)
        testBtn.bezelStyle = .rounded
        content.addSubview(testBtn)

        let closeBtn = NSButton(title: "关闭", target: self, action: #selector(close))
        closeBtn.frame = NSRect(x: 354, y: 72, width: 96, height: 28)
        closeBtn.bezelStyle = .rounded
        content.addSubview(closeBtn)

        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 20, y: 44, width: 430, height: 16)
        content.addSubview(statusLabel)

        let note = NSTextField(wrappingLabelWithString: "数据来自 platform.deepseek.com 平台内部用量接口（非公开 API，可能随时调整）。仅本机使用，token 只存在本地。")
        note.font = .systemFont(ofSize: 9.5)
        note.textColor = .tertiaryLabelColor
        note.frame = NSRect(x: 20, y: 10, width: 430, height: 30)
        content.addSubview(note)
    }

    func show() {
        if !window.isVisible {
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc func close() { window.orderOut(nil) }

    @objc func save() {
        let t = tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else {
            statusLabel.stringValue = "请输入 token"
            statusLabel.textColor = .systemRed
            return
        }
        UserDefaults.standard.set(t, forKey: tokenKey)
        statusLabel.stringValue = "已保存 ✓ 正在刷新…"
        statusLabel.textColor = .secondaryLabelColor
        onChanged?()
    }

    @objc func importChrome() {
        statusLabel.stringValue = "正在读取 Chrome Local Storage…"
        statusLabel.textColor = .secondaryLabelColor
        DispatchQueue.global().async { [weak self] in
            let t = chromeToken()
            DispatchQueue.main.async {
                guard let self else { return }
                if let t {
                    self.tokenField.stringValue = t
                    UserDefaults.standard.set(t, forKey: self.tokenKey)
                    self.statusLabel.stringValue = "已从浏览器读取并保存 ✓ 正在刷新…"
                    self.statusLabel.textColor = .secondaryLabelColor
                    self.onChanged?()
                } else {
                    self.statusLabel.stringValue = "未找到 userToken：请先在 Chrome 登录 platform.deepseek.com"
                    self.statusLabel.textColor = .systemRed
                }
            }
        }
    }

    @objc func test() {
        let t = tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else {
            statusLabel.stringValue = "请先粘贴 token"
            statusLabel.textColor = .systemRed
            return
        }
        statusLabel.stringValue = "测试中…"
        statusLabel.textColor = .secondaryLabelColor
        DeepSeekFetcher(token: t).fetchToday { [weak self] res in
            DispatchQueue.main.async {
                guard let self else { return }
                switch res {
                case .success(let r):
                    let f = r.flash.avgPer1M.map { String(format: "¥%.2f", $0) } ?? "—"
                    let p = r.pro.avgPer1M.map { String(format: "¥%.2f", $0) } ?? "—"
                    self.statusLabel.stringValue = "✓ 连接成功：今日 Flash \(f)/1M · Pro \(p)/1M"
                    self.statusLabel.textColor = .secondaryLabelColor
                case .failure(let e):
                    self.statusLabel.stringValue = "✗ \(e.localizedDescription)"
                    self.statusLabel.textColor = .systemRed
                }
            }
        }
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let tokenKey = "dsUserToken"
    static let windowWidth: CGFloat = 316

    let window: NSPanel
    private let rootView: BaseView
    private let header = HeaderView()
    private let flashCard = CardView()
    private let proCard = CardView()
    private let otherCard = CardView()
    private let footer = FooterView()
    private var settings: SettingsController?
    private var timer: Timer?
    private var report: DayReport?
    private var status: WidgetStatus = .noToken
    private var autoImported = false

    var token: String? {
        if let saved = UserDefaults.standard.string(forKey: Self.tokenKey), !saved.isEmpty {
            return saved
        }
        if let env = ProcessInfo.processInfo.environment["DEEPSEEK_USER_TOKEN"], !env.isEmpty {
            return env
        }
        return nil
    }

    override init() {
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.windowWidth, height: 200),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        rootView = BaseView(frame: NSRect(x: 0, y: 0, width: Self.windowWidth, height: 200))
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        window.orderFrontRegardless()
        startRefresh()
    }

    private func buildWindow() {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)

        rootView.wantsLayer = true
        rootView.layer?.cornerRadius = 16
        rootView.layer?.masksToBounds = true
        rootView.layer?.backgroundColor = NSColor(calibratedRed: 0.086, green: 0.098, blue: 0.125, alpha: 0.97).cgColor
        rootView.layer?.borderWidth = 0.5
        rootView.layer?.borderColor = NSColor(calibratedWhite: 1.0, alpha: 0.10).cgColor
        rootView.onRightClick = { [weak self] event in
            self?.showMenu(event)
        }
        window.contentView = rootView

        flashCard.kind = .flash
        flashCard.toolTip = flashRef.tooltip
        flashCard.onRightClick = { [weak self] e in self?.showMenu(e) }
        proCard.kind = .pro
        proCard.toolTip = proRef.tooltip
        proCard.onRightClick = { [weak self] e in self?.showMenu(e) }
        otherCard.kind = .other
        otherCard.onRightClick = { [weak self] e in self?.showMenu(e) }
        header.onRightClick = { [weak self] e in self?.showMenu(e) }
        footer.onRightClick = { [weak self] e in self?.showMenu(e) }

        rootView.addSubview(header)
        rootView.addSubview(flashCard)
        rootView.addSubview(proCard)
        rootView.addSubview(otherCard)
        rootView.addSubview(footer)

        positionWindow()
    }

    private func positionWindow() {
        guard let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        window.setFrameOrigin(NSPoint(x: f.maxX - Self.windowWidth - 24, y: f.maxY - window.frame.height - 24))
    }

    private func startRefresh() {
        refresh()
        restartTimer()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    static let refreshKey = "dsRefreshSec"
    static let refreshOptions: [(String, Int)] = [("30 秒", 30), ("1 分钟", 60), ("5 分钟", 300)]

    var refreshInterval: TimeInterval {
        let v = UserDefaults.standard.integer(forKey: Self.refreshKey)
        return Self.refreshOptions.contains(where: { $0.1 == v }) ? TimeInterval(v) : 60
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        guard let token else {
            if !autoImported {
                autoImported = true
                DispatchQueue.global().async { [weak self] in
                    if let t = chromeToken() {
                        DispatchQueue.main.async {
                            UserDefaults.standard.set(t, forKey: Self.tokenKey)
                            self?.refresh()
                        }
                    } else {
                        DispatchQueue.main.async {
                            self?.status = .noToken
                            self?.render()
                        }
                    }
                }
            } else {
                status = .noToken
                render()
            }
            return
        }
        status = .loading
        render()
        DeepSeekFetcher(token: token).fetchToday { [weak self] res in
            DispatchQueue.main.async {
                guard let self else { return }
                switch res {
                case .success(let r):
                    self.report = r
                    self.status = .ok
                    self.header.updatedAt = Date()
                    // 若 token 来自环境变量，成功后持久化到本机偏好
                    if UserDefaults.standard.string(forKey: Self.tokenKey)?.isEmpty != false {
                        UserDefaults.standard.set(token, forKey: Self.tokenKey)
                    }
                case .failure(let e):
                    self.status = .error(e.localizedDescription)
                }
                self.render()
            }
        }
    }

    private func render() {
        header.status = status
        header.needsDisplay = true

        flashCard.agg = report?.flash
        proCard.agg = report?.pro
        otherCard.agg = report?.other
        flashCard.needsDisplay = true
        proCard.needsDisplay = true
        otherCard.needsDisplay = true

        footer.report = report
        footer.status = status
        footer.needsDisplay = true

        relayout()
    }

    private func relayout() {
        let w = Self.windowWidth
        let cardW = w - 16
        let headerH: CGFloat = 46
        let cardH: CGFloat = 92
        let footerH: CGFloat = 30
        let showOther = (report?.other.tokens ?? 0) > 0
        let n = showOther ? 3 : 2
        let needed = headerH + 10 + cardH * CGFloat(n) + 8 * CGFloat(n - 1) + 10 + footerH
        if abs(window.frame.height - needed) > 0.5 {
            resizeWindow(toHeight: needed)
        }
        var y = needed - headerH - 10
        flashCard.frame = NSRect(x: 8, y: y - cardH, width: cardW, height: cardH)
        y -= cardH + 8
        proCard.frame = NSRect(x: 8, y: y - cardH, width: cardW, height: cardH)
        y -= cardH + 8
        if showOther {
            otherCard.frame = NSRect(x: 8, y: y - cardH, width: cardW, height: cardH)
            otherCard.isHidden = false
        } else {
            otherCard.isHidden = true
        }
        header.frame = NSRect(x: 0, y: needed - headerH, width: w, height: headerH)
        footer.frame = NSRect(x: 0, y: 0, width: w, height: footerH)
    }

    private func resizeWindow(toHeight h: CGFloat) {
        let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        window.setFrame(NSRect(x: topLeft.x, y: topLeft.y - h, width: Self.windowWidth, height: h), display: true)
    }

    private func showMenu(_ event: NSEvent) {
        let menu = NSMenu()
        let refresh = NSMenuItem(title: "立即刷新", action: #selector(menuRefresh), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let pin = NSMenuItem(title: "始终置顶", action: #selector(menuTogglePin), keyEquivalent: "")
        pin.target = self
        pin.state = window.level == .floating ? .on : .off
        menu.addItem(pin)

        let open = NSMenuItem(title: "打开平台用量页", action: #selector(menuOpenSite), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        // 刷新频率子菜单
        let freq = NSMenu()
        for (label, sec) in Self.refreshOptions {
            let item = NSMenuItem(title: label, action: #selector(menuSetRefresh(_:)), keyEquivalent: "")
            item.target = self
            item.tag = sec
            item.state = Int(refreshInterval) == sec ? .on : .off
            freq.addItem(item)
        }
        let freqItem = NSMenuItem(title: "刷新频率", action: nil, keyEquivalent: "")
        menu.addItem(freqItem)
        menu.setSubmenu(freq, for: freqItem)

        menu.addItem(.separator())
        let set = NSMenuItem(title: "设置 Token…", action: #selector(menuSettings), keyEquivalent: ",")
        set.target = self
        menu.addItem(set)
        let about = NSMenuItem(title: "关于", action: #selector(menuAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        NSMenu.popUpContextMenu(menu, with: event, for: rootView)
    }

    @objc func menuRefresh() { refresh() }

    @objc func menuSetRefresh(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: Self.refreshKey)
        restartTimer()
        refresh()
    }

    @objc func menuTogglePin() {
        window.level = window.level == .floating ? .normal : .floating
    }

    @objc func menuOpenSite() {
        NSWorkspace.shared.open(URL(string: "https://platform.deepseek.com/usage")!)
    }

    @objc func menuSettings() {
        if settings == nil {
            settings = SettingsController()
            settings?.onChanged = { [weak self] in self?.refresh() }
        }
        settings?.show()
    }

    @objc func menuAbout() {
        let alert = NSAlert()
        alert.messageText = "DeepSeek 浮窗 v1.0"
        alert.informativeText = """
        展示当天 V4-Flash / V4-Pro 每百万 token 平均费用与缓存命中率。
        数据来源：platform.deepseek.com 平台用量接口（userToken）。
        峰谷参考（元/百万 tokens，北京时间 9-12 / 14-18 为峰时）：
        Flash 峰 0.10/3.0/9.0 · 闲 0.05/1.5/4.5
        Pro   峰 0.30/9.0/27.0 · 闲 0.15/4.5/13.5
        """
        alert.runModal()
    }

    @objc func menuQuit() { NSApp.terminate(nil) }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // 离屏渲染自检：注入样例数据并导出 PNG
    func injectSample() {
        var r = DayReport()
        r.flash.add(hit: 12_000_000, miss: 3_000_000, out: 2_000_000, req: 340)
        r.flash.addCost(123.45, currency: "CNY")
        r.pro.add(hit: 5_000_000, miss: 20_000_000, out: 6_000_000, req: 120)
        r.pro.addCost(950.00, currency: "CNY")
        r.balance = 88.50
        r.balanceCurrency = "CNY"
        report = r
        status = .ok
        header.updatedAt = Date()
        render()
    }

    var renderOK: Bool {
        if case .ok = status { return true }
        return false
    }

    func debugDump() {
        print("DEBUG bounds=\(window.contentView?.bounds ?? .zero)")
        print("DEBUG header=\(header.frame) flash=\(flashCard.frame) pro=\(proCard.frame) footer=\(footer.frame)")
        if let r = report {
            print("DEBUG flash toks=\(r.flash.tokens) hit=\(r.flash.hit) miss=\(r.flash.miss) out=\(r.flash.out) rate=\(r.flash.hitRate ?? -1) cost=\(r.flash.primaryCost)")
            print("DEBUG pro   toks=\(r.pro.tokens) hit=\(r.pro.hit) miss=\(r.pro.miss) out=\(r.pro.out) rate=\(r.pro.hitRate ?? -1) cost=\(r.pro.primaryCost)")
        } else {
            print("DEBUG report=nil status=\(status)")
        }
    }

    func exportRender(to path: String) {
        window.orderFrontRegardless()
        window.displayIfNeeded()
        let content = window.contentView!
        let rect = content.bounds
        // 按窗口实际 backing scale 渲染（Retina 2x），与真实屏幕显示一致
        let scale = window.backingScaleFactor > 1 ? window.backingScaleFactor : 1
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(rect.width * scale),
            pixelsHigh: Int(rect.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0) else {
            FileHandle.standardError.write(Data("bitmap alloc failed\n".utf8))
            exit(3)
        }
        rep.size = NSSize(width: rect.width, height: rect.height)
        content.cacheDisplay(in: rect, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("PNG encode failed\n".utf8))
            exit(3)
        }
        try? png.write(to: URL(fileURLWithPath: path))
        exit(0)
    }
}

// MARK: - 自检 CLI

func selftestJSON(_ r: DayReport) -> String {
    func aggDict(_ a: Agg) -> [String: Any] {
        [
            "tokens": a.tokens,
            "cacheHit": a.hit,
            "cacheMiss": a.miss,
            "output": a.out,
            "requests": a.req,
            "hitRate": a.hitRate ?? 0,
            "cost": a.cost,
            "avgPer1M": a.avgPer1M as Any,
        ]
    }
    let dict: [String: Any] = [
        "flash": aggDict(r.flash),
        "pro": aggDict(r.pro),
        "other": aggDict(r.other),
        "balance": r.balance as Any,
        "balanceCurrency": r.balanceCurrency as Any,
    ]
    if let d = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) {
        return String(data: d, encoding: .utf8) ?? "{}"
    }
    return "{}"
}

func runSelftest() {
    var token = ProcessInfo.processInfo.environment["DEEPSEEK_USER_TOKEN"] ?? ""
    if let i = CommandLine.arguments.firstIndex(of: "--token"), i + 1 < CommandLine.arguments.count {
        token = CommandLine.arguments[i + 1]
    }
    if token.isEmpty { token = chromeToken() ?? "" }
    guard !token.isEmpty else {
        print("SELFTEST_ERROR: 无 token（传 --token <userToken> 或设置 DEEPSEEK_USER_TOKEN，且本机 Chrome 未找到）")
        exit(2)
    }
    let sem = DispatchSemaphore(value: 0)
    DeepSeekFetcher(token: token).fetchToday { res in
        switch res {
        case .success(let r):
            print(selftestJSON(r))
            exit(0)
        case .failure(let e):
            print("SELFTEST_ERROR: \(e.localizedDescription)")
            exit(1)
        }
        sem.signal()
    }
    sem.wait()
}

// MARK: - 入口

if CommandLine.arguments.contains("--selftest") {
    runSelftest()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)

if CommandLine.arguments.contains("--render-test") {
    let outPath: String
    if let i = CommandLine.arguments.firstIndex(of: "--render-test"), i + 1 < CommandLine.arguments.count {
        outPath = CommandLine.arguments[i + 1]
    } else {
        outPath = "/tmp/deepseek-widget-render.png"
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        delegate.injectSample()
        delegate.exportRender(to: outPath)
    }
}

if CommandLine.arguments.contains("--render-live") {
    let outPath: String
    if let i = CommandLine.arguments.firstIndex(of: "--render-live"), i + 1 < CommandLine.arguments.count {
        outPath = CommandLine.arguments[i + 1]
    } else {
        outPath = "/tmp/deepseek-widget-live.png"
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        delegate.refresh()
        var tries = 0
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
            tries += 1
            if delegate.renderOK || tries > 24 {
                timer.invalidate()
                delegate.debugDump()
                delegate.exportRender(to: outPath)
            }
        }
    }
}

app.run()
