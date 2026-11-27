import Cocoa

// ═══════════════════════════════════════════════════════════
//  La météo
//
//  La source d'abord, parce qu'elle a été choisie par
//  élimination. La météo d'Apple — WeatherKit — exige un
//  compte développeur payant et une application signée par
//  lui ; BUD ne l'est pas. Open-Meteo est gratuit sans clé
//  pour un usage personnel, sous licence CC BY 4.0 : la
//  mention de la source est donc affichée, et elle n'est pas
//  une politesse mais une condition.
//
//  Ce qui part de la machine : les coordonnées d'une ville,
//  arrondies au centième. Pas la position du Mac — BUD ne la
//  demande pas —, pas d'identifiant, pas de clé.
//
//  Le relevé a lieu toutes les trente minutes au plus, et le
//  dernier est gardé sur disque : la météo s'affiche
//  instantanément à l'ouverture, puis se met à jour.
// ═══════════════════════════════════════════════════════════

struct WeatherPlace: Codable, Equatable {
    var name: String
    var country: String
    var latitude: Double
    var longitude: Double
}

struct WeatherHour: Codable {
    var time: Date
    var temp: Double
    var code: Int
    var isDay: Bool
}

struct WeatherDay: Codable {
    var date: Date
    var code: Int
    var tmin: Double
    var tmax: Double
    var rain: Int          // probabilité maximale de précipitation, %
}

struct WeatherReport: Codable {
    var place: WeatherPlace
    var fetchedAt: Date
    var temp: Double
    var feels: Double
    var code: Int
    var isDay: Bool
    var wind: Double
    var humidity: Int
    var hours: [WeatherHour]
    var days: [WeatherDay]

    var condition: WeatherCondition { WeatherCondition(code: code, isDay: isDay) }
}

// ─────────────────────────────────────────────────────────
//  Les codes météo
//
//  Open-Meteo rend le code de l'Organisation météorologique
//  mondiale. On le traduit en trois choses : un libellé en
//  français, un symbole, et une scène — c'est la scène qui
//  décide de l'animation de fond.
// ─────────────────────────────────────────────────────────

enum WeatherScene { case clear, partly, cloudy, fog, drizzle, rain, snow, storm }

struct WeatherCondition {
    let code: Int
    let isDay: Bool

    var scene: WeatherScene {
        switch code {
        case 0:                         return .clear
        case 1, 2:                      return .partly
        case 3:                         return .cloudy
        case 45, 48:                    return .fog
        case 51, 53, 55, 56, 57:        return .drizzle
        case 61, 63, 65, 66, 67, 80, 81, 82: return .rain
        case 71, 73, 75, 77, 85, 86:    return .snow
        case 95, 96, 99:                return .storm
        default:                        return .cloudy
        }
    }

    var label: String {
        switch code {
        case 0:          return isDay ? "Ensoleillé" : "Dégagé"
        case 1:          return "Plutôt dégagé"
        case 2:          return "Partiellement nuageux"
        case 3:          return "Couvert"
        case 45, 48:     return "Brouillard"
        case 51, 53, 55: return "Bruine"
        case 56, 57:     return "Bruine verglaçante"
        case 61:         return "Pluie faible"
        case 63:         return "Pluie"
        case 65:         return "Forte pluie"
        case 66, 67:     return "Pluie verglaçante"
        case 71:         return "Neige faible"
        case 73:         return "Neige"
        case 75:         return "Forte neige"
        case 77:         return "Grains de neige"
        case 80, 81:     return "Averses"
        case 82:         return "Fortes averses"
        case 85, 86:     return "Averses de neige"
        case 95:         return "Orage"
        case 96, 99:     return "Orage et grêle"
        default:         return "—"
        }
    }

    /// Symboles présents depuis macOS 12 : un symbole absent ne
    /// s'affiche pas, il ne retombe sur rien.
    var symbol: String {
        switch scene {
        case .clear:   return isDay ? "sun.max.fill" : "moon.stars.fill"
        case .partly:  return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case .cloudy:  return "cloud.fill"
        case .fog:     return "cloud.fog.fill"
        case .drizzle: return "cloud.drizzle.fill"
        case .rain:    return code == 65 || code == 82 ? "cloud.heavyrain.fill" : "cloud.rain.fill"
        case .snow:    return "cloud.snow.fill"
        case .storm:   return "cloud.bolt.rain.fill"
        }
    }

    /// Intensité 0 à 1 : le nombre de gouttes ou de flocons.
    var intensity: CGFloat {
        switch code {
        case 51, 56, 61, 71, 80, 85: return 0.45
        case 53, 63, 73, 81, 95:     return 0.75
        case 55, 57, 65, 67, 75, 82, 86, 96, 99: return 1.0
        default:                     return 0.6
        }
    }
}

/// Un symbole météo dans ses couleurs d'origine — le soleil jaune, la
/// pluie bleue —, comme dans l'application Météo. `drawSymbol` teinte
/// d'une seule couleur ; ici on veut l'inverse.
func drawWeatherSymbol(_ name: String, center: NSPoint, size: CGFloat) {
    let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        .applying(.preferringMulticolor())
    guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else { return }
    let s = img.size
    img.draw(in: NSRect(x: (center.x - s.width / 2).rounded(),
                        y: (center.y - s.height / 2).rounded(),
                        width: s.width, height: s.height))
}

// ═══════════════════════════════════════════════════════════
//  Le service
// ═══════════════════════════════════════════════════════════

final class WeatherService {
    static let shared = WeatherService()

    private(set) var report: WeatherReport?
    /// Prévenu sur le fil principal quand un relevé arrive.
    var onUpdate: ((WeatherReport?) -> Void)?
    /// La dernière erreur, en clair, ou rien.
    private(set) var trouble = ""

    private let file = budSupportDir.appendingPathComponent("weather.json")
    private var inFlight = false
    private var timer: Timer?

    private init() {
        if let d = try? Data(contentsOf: file) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .secondsSince1970
            report = try? dec.decode(WeatherReport.self, from: d)
        }
    }

    /// Relève toutes les trente minutes. La tolérance laisse le système
    /// regrouper le réveil avec d'autres : une météo n'a pas besoin de
    /// la seconde près.
    func start(city: @escaping () -> String) {
        guard timer == nil else { return }
        refresh(city: city())
        let t = Timer(timeInterval: 30 * 60, repeats: true) { [weak self] _ in
            self?.refresh(city: city())
        }
        t.tolerance = 120
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// `force` ignore la fraîcheur du relevé gardé.
    func refresh(city: String, force: Bool = false) {
        let name = city.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !inFlight else { return }
        if !force, let r = report,
           r.place.name.lowercased() == name.lowercased() || placeKey == name.lowercased(),
           Date().timeIntervalSince(r.fetchedAt) < 25 * 60 { return }
        inFlight = true

        geocode(name) { [weak self] place in
            guard let s = self else { return }
            guard let place = place else {
                s.finish(nil, trouble: "Ville introuvable : « \(name) ».")
                return
            }
            s.placeKey = name.lowercased()
            s.forecast(place) { rep in
                s.finish(rep, trouble: rep == nil ? "Météo indisponible pour l'instant." : "")
            }
        }
    }

    /// La ville telle qu'elle a été tapée, pour reconnaître un relevé déjà
    /// fait quand le nom rendu par le service diffère — « paris » tapé,
    /// « Paris » rendu.
    private var placeKey = ""

    private func finish(_ r: WeatherReport?, trouble t: String) {
        DispatchQueue.main.async {
            self.inFlight = false
            self.trouble = t
            if let r = r {
                self.report = r
                let enc = JSONEncoder()
                enc.dateEncodingStrategy = .secondsSince1970
                if let d = try? enc.encode(r) { try? d.write(to: self.file, options: .atomic) }
            }
            self.onUpdate?(self.report)
        }
    }

    // ─────────────────────────────────────────────────────────
    //  Réseau
    // ─────────────────────────────────────────────────────────

    private func get(_ url: URL, done: @escaping ([String: Any]?) -> Void) {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("BUD-Premium/\(budVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            guard let data = data,
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { done(nil); return }
            done(obj)
        }.resume()
    }

    private func geocode(_ name: String, done: @escaping (WeatherPlace?) -> Void) {
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [URLQueryItem(name: "name", value: name),
                        URLQueryItem(name: "count", value: "1"),
                        URLQueryItem(name: "language", value: "fr"),
                        URLQueryItem(name: "format", value: "json")]
        guard let url = c.url else { done(nil); return }
        get(url) { obj in
            guard let r = (obj?["results"] as? [[String: Any]])?.first,
                  let lat = r["latitude"] as? Double, let lon = r["longitude"] as? Double
            else { done(nil); return }
            done(WeatherPlace(name: r["name"] as? String ?? name,
                              country: r["country"] as? String ?? "",
                              latitude: lat, longitude: lon))
        }
    }

    private func forecast(_ p: WeatherPlace, done: @escaping (WeatherReport?) -> Void) {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        // Coordonnées arrondies au centième, un peu plus d'un kilomètre :
        // la précision d'un modèle météo, pas celle d'une adresse.
        let lat = (p.latitude * 100).rounded() / 100
        let lon = (p.longitude * 100).rounded() / 100
        c.queryItems = [
            URLQueryItem(name: "latitude", value: String(lat)),
            URLQueryItem(name: "longitude", value: String(lon)),
            URLQueryItem(name: "current", value: "temperature_2m,relative_humidity_2m,"
                         + "apparent_temperature,is_day,weather_code,wind_speed_10m"),
            URLQueryItem(name: "hourly", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,"
                         + "temperature_2m_min,precipitation_probability_max"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "7")
        ]
        guard let url = c.url else { done(nil); return }
        get(url) { obj in done(obj.flatMap { WeatherService.parse($0, place: p) }) }
    }

    /// Fonction pure : rejouable sur une réponse enregistrée.
    static func parse(_ o: [String: Any], place: WeatherPlace) -> WeatherReport? {
        guard let cur = o["current"] as? [String: Any] else { return nil }
        let offset = o["utc_offset_seconds"] as? Int ?? 0

        // Les heures arrivent en heure locale du lieu, sans fuseau :
        // « 2026-11-27T17:00 ». On les lit dans le fuseau du lieu.
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(secondsFromGMT: offset)
        func date(_ s: Any?, _ f: String) -> Date? {
            guard let s = s as? String else { return nil }
            fmt.dateFormat = f
            return fmt.date(from: s)
        }
        func num(_ a: Any?) -> Double { (a as? NSNumber)?.doubleValue ?? 0 }

        var hours: [WeatherHour] = []
        if let h = o["hourly"] as? [String: Any],
           let times = h["time"] as? [Any],
           let temps = h["temperature_2m"] as? [Any],
           let codes = h["weather_code"] as? [Any] {
            let days = h["is_day"] as? [Any] ?? []
            let now = Date().addingTimeInterval(-3600)
            for i in times.indices where i < temps.count && i < codes.count {
                guard let t = date(times[i], "yyyy-MM-dd'T'HH:mm"), t >= now else { continue }
                hours.append(WeatherHour(time: t, temp: num(temps[i]), code: Int(num(codes[i])),
                                         isDay: i < days.count ? num(days[i]) > 0 : true))
                if hours.count >= 24 { break }
            }
        }

        var days: [WeatherDay] = []
        if let d = o["daily"] as? [String: Any],
           let times = d["time"] as? [Any],
           let codes = d["weather_code"] as? [Any],
           let tmax = d["temperature_2m_max"] as? [Any],
           let tmin = d["temperature_2m_min"] as? [Any] {
            let rain = d["precipitation_probability_max"] as? [Any] ?? []
            for i in times.indices where i < codes.count && i < tmax.count && i < tmin.count {
                guard let t = date(times[i], "yyyy-MM-dd") else { continue }
                days.append(WeatherDay(date: t, code: Int(num(codes[i])),
                                       tmin: num(tmin[i]), tmax: num(tmax[i]),
                                       rain: i < rain.count ? Int(num(rain[i])) : 0))
            }
        }

        return WeatherReport(place: place, fetchedAt: Date(),
                             temp: num(cur["temperature_2m"]),
                             feels: num(cur["apparent_temperature"]),
                             code: Int(num(cur["weather_code"])),
                             isDay: num(cur["is_day"]) > 0,
                             wind: num(cur["wind_speed_10m"]),
                             humidity: Int(num(cur["relative_humidity_2m"])),
                             hours: hours, days: days)
    }

    /// Une phrase pour le chat et pour la pastille.
    func summary() -> String {
        guard let r = report else {
            return trouble.isEmpty ? "Je n'ai pas encore de relevé météo." : trouble
        }
        var s = "\(r.place.name) : \(Int(r.temp.rounded()))°, \(r.condition.label.lowercased())"
        if let d = r.days.first {
            s += ". Max \(Int(d.tmax.rounded()))°, min \(Int(d.tmin.rounded()))°"
            if d.rain >= 30 { s += ", \(d.rain) % de risque de pluie" }
        }
        return s + "."
    }
}

// ═══════════════════════════════════════════════════════════
//  La scène animée
//
//  Le fond de l'application Météo n'est pas une image : c'est
//  un ciel qui bouge. Soleil qui rayonne, nuages qui dérivent
//  sur trois plans à des vitesses différentes, pluie oblique,
//  neige qui oscille, éclair qui illumine tout le ciel.
//
//  Tout est dessiné, rien n'est chargé. Les particules sont
//  tirées une fois, d'une graine fixe : elles recommencent
//  leur course au lieu d'être recréées, et la scène ne coûte
//  pas plus à la centième seconde qu'à la première.
//
//  L'horloge ne tourne que quand la vue est visible. Un
//  panneau caché qui redessine trente fois par seconde est
//  une batterie qui fond pour personne.
// ═══════════════════════════════════════════════════════════

final class WeatherSceneView: NSView {

    var condition = WeatherCondition(code: 1, isDay: true) {
        didSet { needsDisplay = true }
    }

    private var timer: Timer?
    private var t: CGFloat = 0
    private var flash: CGFloat = 0
    private var nextBolt: CGFloat = 3

    private struct Drop { var x: CGFloat; var y: CGFloat; var speed: CGFloat; var len: CGFloat; var size: CGFloat; var phase: CGFloat }
    private var drops: [Drop] = []
    private var stars: [(CGPoint, CGFloat, CGFloat)] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.masksToBounds = true
        // Graine fixe : la même pluie à chaque ouverture, et aucune
        // allocation pendant l'animation.
        var g = SeededRandom(seed: 27)
        for _ in 0..<160 {
            drops.append(Drop(x: g.next(), y: g.next(), speed: 0.6 + g.next() * 0.6,
                              len: 0.7 + g.next() * 0.6, size: 0.6 + g.next() * 0.8,
                              phase: g.next() * 6.28))
        }
        for _ in 0..<70 {
            stars.append((CGPoint(x: g.next(), y: 0.35 + g.next() * 0.65),
                          0.6 + g.next() * 1.3, g.next() * 6.28))
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateClock()
    }
    override func viewDidHide() { super.viewDidHide(); updateClock() }
    override func viewDidUnhide() { super.viewDidUnhide(); updateClock() }

    func updateClock() {
        let visible = window != nil && !isHiddenOrHasHiddenAncestor
        if visible && timer == nil {
            let tm = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(tm, forMode: .common)
            timer = tm
        } else if !visible {
            timer?.invalidate()
            timer = nil
        }
    }

    private func tick() {
        guard !isHiddenOrHasHiddenAncestor else { updateClock(); return }
        // Fenêtre repliée : l'horloge reste, mais on ne dessine plus rien.
        guard window?.isVisible == true,
              window?.occlusionState.contains(.visible) == true else { return }
        t += 1.0 / 30.0
        if condition.scene == .storm {
            if t >= nextBolt {
                flash = 1
                // Irrégulier, comme un orage : entre trois et neuf secondes.
                nextBolt = t + 3 + CGFloat(abs(sin(t * 12.9898)) * 6)
            }
            flash = max(0, flash - 0.07)
        } else {
            flash = 0
        }
        needsDisplay = true
    }

    // ─────────────────────────────────────────────────────────
    //  Les ciels
    //
    //  Les dégradés reprennent ceux de l'application Météo : un
    //  bleu franc et lumineux le jour, un bleu nuit presque
    //  noir, des gris bleutés quand le ciel se couvre, plus
    //  sombres sous la pluie, presque violets sous l'orage.
    // ─────────────────────────────────────────────────────────

    private func sky() -> [NSColor] {
        func c(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
            NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        }
        let day = condition.isDay
        switch condition.scene {
        case .clear:   return day ? [c(46, 120, 214), c(110, 172, 235)] : [c(8, 16, 42), c(28, 46, 92)]
        case .partly:  return day ? [c(64, 128, 204), c(132, 176, 222)] : [c(14, 22, 48), c(40, 56, 96)]
        case .cloudy:  return day ? [c(96, 118, 146), c(150, 168, 188)] : [c(26, 32, 46), c(56, 64, 82)]
        case .fog:     return day ? [c(132, 142, 154), c(182, 188, 196)] : [c(38, 42, 50), c(70, 74, 84)]
        case .drizzle, .rain:
                       return day ? [c(60, 78, 102), c(108, 126, 148)] : [c(18, 24, 36), c(44, 54, 70)]
        case .snow:    return day ? [c(118, 140, 168), c(196, 210, 226)] : [c(30, 38, 58), c(78, 90, 116)]
        case .storm:   return day ? [c(42, 44, 66), c(82, 84, 112)] : [c(12, 12, 24), c(38, 36, 58)]
        }
    }

    override func draw(_ dirty: NSRect) {
        let b = bounds
        let colors = sky()
        NSGradient(colors: [colors[1], colors[0]])?.draw(in: b, angle: 90)

        let scene = condition.scene
        let day = condition.isDay

        if !day && (scene == .clear || scene == .partly) { drawStars(b) }
        if scene == .clear || scene == .partly {
            if day { drawSun(b) } else { drawMoon(b) }
        }
        switch scene {
        case .partly:
            drawClouds(b, layers: 2, opacity: day ? 0.85 : 0.35, dark: !day)
        case .cloudy:
            drawClouds(b, layers: 3, opacity: day ? 0.75 : 0.45, dark: true)
        case .fog:
            drawClouds(b, layers: 2, opacity: 0.35, dark: false)
            drawFog(b)
        case .drizzle:
            drawClouds(b, layers: 3, opacity: 0.55, dark: true)
            drawRain(b, amount: 0.35, heavy: false)
        case .rain:
            drawClouds(b, layers: 3, opacity: 0.55, dark: true)
            drawRain(b, amount: condition.intensity, heavy: condition.intensity > 0.9)
        case .snow:
            drawClouds(b, layers: 2, opacity: 0.5, dark: false)
            drawSnow(b, amount: condition.intensity)
        case .storm:
            drawClouds(b, layers: 3, opacity: 0.65, dark: true)
            drawRain(b, amount: 1, heavy: true)
            drawLightning(b)
        case .clear:
            break
        }

        // Un voile en bas : le texte et les cartes posés dessus restent
        // lisibles quel que soit le ciel.
        NSGradient(colors: [NSColor.black.withAlphaComponent(0.28), .clear])?
            .draw(in: NSRect(x: 0, y: 0, width: b.width, height: b.height * 0.55), angle: 90)
    }

    private func drawSun(_ b: NSRect) {
        let c = CGPoint(x: b.maxX - b.width * 0.18, y: b.maxY - b.height * 0.16)
        let r = min(b.width, b.height) * 0.09
        // Le halo respire lentement ; les rayons tournent à peine.
        let breath = 1 + 0.06 * sin(t * 0.9)
        NSGradient(colors: [NSColor(srgbRed: 1, green: 0.93, blue: 0.62, alpha: 0.55),
                            NSColor(srgbRed: 1, green: 0.85, blue: 0.45, alpha: 0)])?
            .draw(in: NSRect(x: c.x - r * 4.2 * breath, y: c.y - r * 4.2 * breath,
                             width: r * 8.4 * breath, height: r * 8.4 * breath),
                  relativeCenterPosition: .zero)
        NSGraphicsContext.current?.saveGraphicsState()
        let tr = NSAffineTransform()
        tr.translateX(by: c.x, yBy: c.y)
        tr.rotate(byRadians: t * 0.05)
        tr.concat()
        NSColor(srgbRed: 1, green: 0.95, blue: 0.75, alpha: 0.10).setFill()
        for i in 0..<12 {
            let a = CGFloat(i) / 12 * .pi * 2
            let p = NSBezierPath()
            p.move(to: .zero)
            p.line(to: CGPoint(x: cos(a - 0.06) * r * 6, y: sin(a - 0.06) * r * 6))
            p.line(to: CGPoint(x: cos(a + 0.06) * r * 6, y: sin(a + 0.06) * r * 6))
            p.close()
            p.fill()
        }
        NSGraphicsContext.current?.restoreGraphicsState()
        NSGradient(colors: [NSColor(srgbRed: 1, green: 0.98, blue: 0.86, alpha: 1),
                            NSColor(srgbRed: 1, green: 0.86, blue: 0.42, alpha: 1)])?
            .draw(in: NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                  relativeCenterPosition: NSPoint(x: -0.3, y: 0.3))
    }

    private func drawMoon(_ b: NSRect) {
        let c = CGPoint(x: b.maxX - b.width * 0.20, y: b.maxY - b.height * 0.18)
        let r = min(b.width, b.height) * 0.07
        NSGradient(colors: [NSColor(white: 1, alpha: 0.22), NSColor(white: 1, alpha: 0)])?
            .draw(in: NSRect(x: c.x - r * 3.5, y: c.y - r * 3.5, width: r * 7, height: r * 7),
                  relativeCenterPosition: .zero)
        // Un croissant : un disque clair, mordu par un disque de la
        // couleur du ciel.
        NSColor(srgbRed: 0.96, green: 0.95, blue: 0.88, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)).fill()
        sky()[0].blended(withFraction: 0.35, of: sky()[1])?.setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - r * 0.45, y: c.y - r * 0.75, width: r * 2, height: r * 2)).fill()
    }

    private func drawStars(_ b: NSRect) {
        for (p, size, ph) in stars {
            let tw = 0.35 + 0.65 * (0.5 + 0.5 * sin(t * 1.6 + ph))
            NSColor(white: 1, alpha: 0.55 * tw).setFill()
            let s = size * (0.8 + 0.3 * tw)
            NSBezierPath(ovalIn: NSRect(x: p.x * b.width - s / 2, y: p.y * b.height - s / 2,
                                        width: s, height: s)).fill()
        }
    }

    /// Un nuage : cinq disques qui se chevauchent sur une base plate.
    private func cloud(at c: CGPoint, w: CGFloat, color: NSColor) {
        let h = w * 0.42
        let p = NSBezierPath()
        p.appendRoundedRect(NSRect(x: c.x - w / 2, y: c.y - h * 0.25, width: w, height: h * 0.5),
                            xRadius: h * 0.25, yRadius: h * 0.25)
        let lobes: [(CGFloat, CGFloat, CGFloat)] = [(-0.30, 0.10, 0.26), (-0.08, 0.28, 0.34),
                                                    (0.18, 0.20, 0.28), (0.34, 0.04, 0.20),
                                                    (-0.42, -0.02, 0.17)]
        for (dx, dy, r) in lobes {
            p.appendOval(in: NSRect(x: c.x + dx * w - r * w / 2, y: c.y + dy * h * 1.4 - r * w / 2,
                                    width: r * w, height: r * w))
        }
        color.setFill()
        p.fill()
    }

    private func drawClouds(_ b: NSRect, layers: Int, opacity: CGFloat, dark: Bool) {
        // Trois plans : le plus lointain est le plus petit, le plus pâle
        // et le plus lent. C'est la différence de vitesse qui donne la
        // profondeur, pas la taille.
        let specs: [(y: CGFloat, w: CGFloat, speed: CGFloat, alpha: CGFloat, n: Int)] = [
            (0.80, 0.30, 4, 0.55, 3), (0.68, 0.42, 7, 0.75, 3), (0.86, 0.55, 11, 1.0, 2)
        ]
        for (i, s) in specs.prefix(layers).enumerated() {
            let base = dark ? NSColor(white: 0.78 - CGFloat(i) * 0.08, alpha: 1) : NSColor(white: 1, alpha: 1)
            let col = base.withAlphaComponent(opacity * s.alpha)
            let w = b.width * s.w
            let span = b.width + w
            for k in 0..<s.n {
                let x0 = CGFloat(k) / CGFloat(s.n) * span + CGFloat(i) * 47
                let x = (x0 + t * s.speed).truncatingRemainder(dividingBy: span) - w / 2
                let y = b.height * s.y + sin(t * 0.3 + CGFloat(k * 2 + i)) * 3
                cloud(at: CGPoint(x: x, y: y), w: w, color: col)
            }
        }
    }

    private func drawRain(_ b: NSRect, amount: CGFloat, heavy: Bool) {
        let n = Int(CGFloat(drops.count) * max(0.2, min(1, amount)))
        let slant: CGFloat = 0.18
        let p = NSBezierPath()
        p.lineWidth = heavy ? 1.6 : 1.2
        p.lineCapStyle = .round
        for d in drops.prefix(n) {
            let fall = (d.y + t * d.speed * (heavy ? 1.3 : 1.0)).truncatingRemainder(dividingBy: 1.15)
            let y = b.maxY - fall * b.height
            let x = d.x * (b.width + 40) - 20 - fall * b.height * slant
            let len = (heavy ? 22 : 15) * d.len
            p.move(to: CGPoint(x: x, y: y))
            p.line(to: CGPoint(x: x + len * slant, y: y + len))
        }
        NSColor(srgbRed: 0.82, green: 0.90, blue: 1, alpha: heavy ? 0.55 : 0.42).setStroke()
        p.stroke()
    }

    private func drawSnow(_ b: NSRect, amount: CGFloat) {
        let n = Int(CGFloat(drops.count) * 0.7 * max(0.3, min(1, amount)))
        NSColor(white: 1, alpha: 0.85).setFill()
        for d in drops.prefix(n) {
            let fall = (d.y + t * d.speed * 0.12).truncatingRemainder(dividingBy: 1.1)
            let y = b.maxY - fall * b.height
            // Le flocon oscille : il tombe en se balançant, pas en ligne.
            let x = d.x * b.width + sin(t * 1.2 + d.phase) * 9
            let s = 2 + d.size * 2.2
            NSBezierPath(ovalIn: NSRect(x: x - s / 2, y: y - s / 2, width: s, height: s)).fill()
        }
    }

    private func drawFog(_ b: NSRect) {
        for i in 0..<4 {
            let y = b.height * (0.18 + CGFloat(i) * 0.17)
            let x = sin(t * 0.15 + CGFloat(i)) * 40
            let band = NSRect(x: x - 60, y: y, width: b.width + 120, height: b.height * 0.12)
            NSGradient(colors: [NSColor(white: 1, alpha: 0), NSColor(white: 1, alpha: 0.16),
                                NSColor(white: 1, alpha: 0)])?.draw(in: band, angle: 90)
        }
    }

    private func drawLightning(_ b: NSRect) {
        guard flash > 0 else { return }
        // L'éclair illumine tout le ciel une fraction de seconde : c'est
        // la lumière qu'on remarque, l'arc vient après.
        NSColor(white: 1, alpha: 0.35 * flash).setFill()
        b.fill(using: .sourceOver)
        if flash > 0.55 {
            let x0 = b.width * (0.3 + 0.4 * abs(sin(nextBolt * 3.1)))
            let p = NSBezierPath()
            p.move(to: CGPoint(x: x0, y: b.maxY))
            var x = x0, y = b.maxY
            var k: CGFloat = 1
            while y > b.height * 0.45 {
                y -= b.height * 0.07
                x += (sin(k * 7.7 + nextBolt) * 14)
                p.line(to: CGPoint(x: x, y: y))
                k += 1
            }
            p.lineWidth = 2
            NSColor(srgbRed: 0.95, green: 0.95, blue: 1, alpha: flash).setStroke()
            p.stroke()
        }
    }
}

/// Générateur déterministe : la même suite à chaque ouverture.
struct SeededRandom {
    private var s: UInt64
    init(seed: UInt64) { s = seed &* 0x9E3779B97F4A7C15 }
    mutating func next() -> CGFloat {
        s ^= s << 13; s ^= s >> 7; s ^= s << 17
        return CGFloat(s % 1_000_000) / 1_000_000
    }
}

// ═══════════════════════════════════════════════════════════
//  Le panneau Météo
//
//  La disposition de l'application Météo : la ville, la
//  température en grand et en léger, le ciel en mots, le
//  maximum et le minimum. Puis les heures qui viennent, en
//  bande. Puis la semaine, avec pour chaque jour une barre
//  qui situe ses températures dans celles de toute la
//  semaine — c'est ce qui permet de voir d'un coup d'œil
//  qu'il fera froid jeudi.
// ═══════════════════════════════════════════════════════════

final class WeatherPanelView: NSView {

    private let scene: WeatherSceneView
    private let overlay: WeatherOverlay
    private var cityField: NSTextField!
    var onCity: ((String) -> Void)?
    var onRefresh: (() -> Void)?

    override init(frame: NSRect) {
        scene = WeatherSceneView(frame: NSRect(origin: .zero, size: frame.size))
        overlay = WeatherOverlay(frame: NSRect(origin: .zero, size: frame.size))
        super.init(frame: frame)
        scene.autoresizingMask = [.width, .height]
        overlay.autoresizingMask = [.width, .height]
        addSubview(scene)
        addSubview(overlay)

        let W = frame.width
        cityField = NSTextField(frame: NSRect(x: W - 252, y: 12, width: 150, height: 24))
        cityField.placeholderString = "Ville"
        cityField.bezelStyle = .roundedBezel
        cityField.font = NSFont.systemFont(ofSize: 12)
        cityField.target = self
        cityField.action = #selector(cityEntered)
        addSubview(cityField)

        let refresh = GlassButton(frame: NSRect(x: W - 94, y: 10, width: 80, height: 28),
                                  title: "Actualiser", icon: "arrow.clockwise", compact: true)
        refresh.onClick = { [weak self] _ in self?.onRefresh?() }
        addSubview(refresh)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func cityEntered() {
        let c = cityField.stringValue.trimmingCharacters(in: .whitespaces)
        if !c.isEmpty { onCity?(c) }
    }

    func apply(_ r: WeatherReport?, city: String, trouble: String) {
        if cityField.currentEditor() == nil { cityField.stringValue = city }
        overlay.report = r
        overlay.trouble = trouble
        if let r = r { scene.condition = r.condition }
        overlay.needsDisplay = true
        scene.updateClock()
    }

    override func viewDidUnhide() { super.viewDidUnhide(); scene.updateClock() }
    override func viewDidHide() { super.viewDidHide(); scene.updateClock() }
}

/// Le texte et les cartes, posés sur la scène. Une vue à part : la scène
/// se redessine trente fois par seconde, le texte une fois par relevé.
final class WeatherOverlay: NSView {
    var report: WeatherReport?
    var trouble = ""

    override func hitTest(_ p: NSPoint) -> NSView? { nil }

    private let white = NSColor.white
    private func soft(_ a: CGFloat) -> NSColor { NSColor.white.withAlphaComponent(a) }

    override func draw(_ dirty: NSRect) {
        let b = bounds
        guard let r = report else {
            drawString(trouble.isEmpty ? "Relevé en cours…" : trouble,
                       in: NSRect(x: 0, y: b.midY - 10, width: b.width, height: 20),
                       size: 14, weight: .semibold, color: soft(0.85), align: .center)
            return
        }
        NSGraphicsContext.current?.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowColor = NSColor.black.withAlphaComponent(0.25)
        sh.shadowBlurRadius = 6
        sh.shadowOffset = NSSize(width: 0, height: -1)
        sh.set()

        // ── L'en-tête ──
        let top = b.maxY
        drawString(r.place.name, in: NSRect(x: 0, y: top - 44, width: b.width, height: 26),
                   size: 22, weight: .semibold, color: white, align: .center)
        drawString("\(Int(r.temp.rounded()))°",
                   in: NSRect(x: 0, y: top - 112, width: b.width + 12, height: 70),
                   size: 64, weight: .thin, color: white, align: .center)
        drawString(r.condition.label, in: NSRect(x: 0, y: top - 136, width: b.width, height: 20),
                   size: 15, weight: .medium, color: soft(0.92), align: .center)
        if let d = r.days.first {
            drawString("Max. \(Int(d.tmax.rounded()))°  Min. \(Int(d.tmin.rounded()))°",
                       in: NSRect(x: 0, y: top - 158, width: b.width, height: 18),
                       size: 13, weight: .medium, color: soft(0.85), align: .center)
        }
        NSGraphicsContext.current?.restoreGraphicsState()

        // ── Les heures ──
        let hourCard = NSRect(x: 16, y: top - 270, width: b.width - 32, height: 100)
        card(hourCard)
        let feels = Int(r.feels.rounded())
        drawString("Ressenti \(feels)° · vent \(Int(r.wind.rounded())) km/h · humidité \(r.humidity) %",
                   in: NSRect(x: hourCard.minX + 14, y: hourCard.maxY - 22,
                              width: hourCard.width - 28, height: 15),
                   size: 11, weight: .medium, color: soft(0.70))
        NSColor.white.withAlphaComponent(0.15).setFill()
        NSRect(x: hourCard.minX + 14, y: hourCard.maxY - 27, width: hourCard.width - 28, height: 0.5).fill()

        let hours = Array(r.hours.prefix(12))
        if !hours.isEmpty {
            let cw = (hourCard.width - 20) / CGFloat(hours.count)
            let hf = DateFormatter()
            hf.locale = Locale(identifier: "fr_FR")
            hf.dateFormat = "HH"
            for (i, h) in hours.enumerated() {
                let cx = hourCard.minX + 10 + cw * (CGFloat(i) + 0.5)
                let label = i == 0 ? "Maint." : hf.string(from: h.time) + " h"
                drawString(label, in: NSRect(x: cx - cw / 2, y: hourCard.minY + 50, width: cw, height: 14),
                           size: 10.5, weight: .semibold, color: soft(0.85), align: .center)
                drawWeatherSymbol(WeatherCondition(code: h.code, isDay: h.isDay).symbol,
                                  center: NSPoint(x: cx, y: hourCard.minY + 36), size: 15)
                drawString("\(Int(h.temp.rounded()))°",
                           in: NSRect(x: cx - cw / 2, y: hourCard.minY + 8, width: cw + 4, height: 16),
                           size: 12.5, weight: .semibold, color: white, align: .center)
            }
        }

        // ── La semaine ──
        let dayCard = NSRect(x: 16, y: 48, width: b.width - 32, height: hourCard.minY - 58)
        card(dayCard)
        drawSymbol("calendar", center: NSPoint(x: dayCard.minX + 20, y: dayCard.maxY - 15),
                   size: 10, weight: .semibold, color: soft(0.6))
        drawString("PRÉVISIONS SUR 7 JOURS",
                   in: NSRect(x: dayCard.minX + 30, y: dayCard.maxY - 22, width: 220, height: 14),
                   size: 10, weight: .semibold, color: soft(0.6))

        let days = Array(r.days.prefix(7))
        guard !days.isEmpty else { return }
        let lo = days.map { $0.tmin }.min() ?? 0
        let hi = days.map { $0.tmax }.max() ?? 1
        let span = max(1, hi - lo)
        let rowH = (dayCard.height - 30) / CGFloat(days.count)
        let df = DateFormatter()
        df.locale = Locale(identifier: "fr_FR")
        df.dateFormat = "EEE"
        let barX = dayCard.minX + dayCard.width * 0.50
        let barW = dayCard.width * 0.30

        for (i, d) in days.enumerated() {
            let y = dayCard.maxY - 30 - rowH * CGFloat(i + 1)
            let mid = y + rowH / 2
            if i > 0 {
                NSColor.white.withAlphaComponent(0.12).setFill()
                NSRect(x: dayCard.minX + 14, y: y + rowH - 0.5, width: dayCard.width - 28, height: 0.5).fill()
            }
            let name = i == 0 ? "Auj." : df.string(from: d.date).capitalized
            drawString(name, in: NSRect(x: dayCard.minX + 14, y: mid - 9, width: 60, height: 18),
                       size: 13.5, weight: .semibold, color: white)
            let cond = WeatherCondition(code: d.code, isDay: true)
            drawWeatherSymbol(cond.symbol, center: NSPoint(x: dayCard.minX + 96, y: mid + (d.rain >= 20 ? 4 : 0)),
                              size: 15)
            // La probabilité de pluie sous le symbole, en bleu clair, et
            // seulement quand elle compte : à dix pour cent, l'afficher
            // inquiéterait pour rien.
            if d.rain >= 20 {
                drawString("\(d.rain) %", in: NSRect(x: dayCard.minX + 76, y: mid - 16, width: 40, height: 12),
                           size: 9.5, weight: .bold,
                           color: NSColor(srgbRed: 0.55, green: 0.80, blue: 1, alpha: 1), align: .center)
            }
            drawString("\(Int(d.tmin.rounded()))°",
                       in: NSRect(x: barX - 46, y: mid - 9, width: 38, height: 18),
                       size: 13.5, weight: .medium, color: soft(0.6), align: .right)
            drawString("\(Int(d.tmax.rounded()))°",
                       in: NSRect(x: barX + barW + 8, y: mid - 9, width: 38, height: 18),
                       size: 13.5, weight: .semibold, color: white)

            // La barre de la semaine : la piste couvre toute l'amplitude
            // des sept jours, le segment coloré celle du jour.
            let track = NSRect(x: barX, y: mid - 2.5, width: barW, height: 5)
            NSColor.black.withAlphaComponent(0.22).setFill()
            NSBezierPath(roundedRect: track, xRadius: 2.5, yRadius: 2.5).fill()
            let x0 = barX + barW * CGFloat((d.tmin - lo) / span)
            let x1 = barX + barW * CGFloat((d.tmax - lo) / span)
            let seg = NSRect(x: x0, y: track.minY, width: max(5, x1 - x0), height: 5)
            NSGraphicsContext.current?.saveGraphicsState()
            NSBezierPath(roundedRect: seg, xRadius: 2.5, yRadius: 2.5).addClip()
            // Le dégradé est celui de toute la semaine, découpé par le
            // segment : un jour froid est bleu, un jour doux jaune.
            NSGradient(colors: [tempColor(lo), tempColor((lo + hi) / 2), tempColor(hi)])?
                .draw(in: track, angle: 0)
            NSGraphicsContext.current?.restoreGraphicsState()

            // Aujourd'hui : un point blanc à la température actuelle.
            if i == 0 {
                let xn = barX + barW * CGFloat(max(0, min(1, (r.temp - lo) / span)))
                NSColor.black.withAlphaComponent(0.35).setFill()
                NSBezierPath(ovalIn: NSRect(x: xn - 4.5, y: mid - 4.5, width: 9, height: 9)).fill()
                NSColor.white.setFill()
                NSBezierPath(ovalIn: NSRect(x: xn - 3, y: mid - 3, width: 6, height: 6)).fill()
            }
        }

        // ── La source ──
        let ago = Int(Date().timeIntervalSince(r.fetchedAt) / 60)
        let when = ago < 1 ? "à l'instant" : (ago < 60 ? "il y a \(ago) min" : "il y a \(ago / 60) h")
        drawString("Données Open-Meteo · CC BY 4.0 · mis à jour \(when)",
                   in: NSRect(x: 18, y: 16, width: b.width - 290, height: 14),
                   size: 9.5, weight: .medium, color: soft(0.55))
    }

    /// Une carte de verre : fond sombre translucide et liseré clair.
    private func card(_ r: NSRect) {
        let p = NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14)
        NSColor.black.withAlphaComponent(0.20).setFill()
        p.fill()
        NSColor.white.withAlphaComponent(0.14).setStroke()
        p.lineWidth = 0.8
        p.stroke()
    }

    /// Du bleu froid au orange chaud, comme les barres de l'application
    /// Météo : −5° bleu, 10° vert d'eau, 20° jaune, 30° orange.
    private func tempColor(_ c: Double) -> NSColor {
        let stops: [(Double, (CGFloat, CGFloat, CGFloat))] = [
            (-5, (0.35, 0.60, 1.00)), (5, (0.38, 0.82, 0.95)), (12, (0.55, 0.88, 0.62)),
            (20, (0.98, 0.84, 0.30)), (28, (1.00, 0.58, 0.22)), (36, (0.96, 0.32, 0.24))
        ]
        if c <= stops[0].0 { let v = stops[0].1; return NSColor(srgbRed: v.0, green: v.1, blue: v.2, alpha: 1) }
        for i in 1..<stops.count where c <= stops[i].0 {
            let (a0, c0) = stops[i - 1], (a1, c1) = stops[i]
            let f = CGFloat((c - a0) / (a1 - a0))
            return NSColor(srgbRed: c0.0 + (c1.0 - c0.0) * f, green: c0.1 + (c1.1 - c0.1) * f,
                           blue: c0.2 + (c1.2 - c0.2) * f, alpha: 1)
        }
        let v = stops[stops.count - 1].1
        return NSColor(srgbRed: v.0, green: v.1, blue: v.2, alpha: 1)
    }
}
