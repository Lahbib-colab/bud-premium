import Foundation

// ═══════════════════════════════════════════════════════════
//  Données d'exemple du Flux
//
//  De quoi tout voir sans rien toucher : le bouton « Démo »
//  et le mode simulation de chaque agent passent par ici.
//  Les chemins ne pointent sur rien de réel, et la fiche
//  d'approbation d'une simulation ne met rien à la corbeille.
//
//  Chaque jeu est choisi pour faire apparaître une expression
//  précise de BUDs :
//    • nettoyage    → réfléchi (fiche à valider), puis content
//    • sécurité     → agacé (un sosie de PayPal, une IP nue)
//    • météo/maison → cool (ciel dégagé)
//  et `expressionTour` passe les huit en revue.
// ═══════════════════════════════════════════════════════════

enum BudFlowSamples {

    private static let dl = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    private static let lib = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")

    // ── Nettoyage ──

    static let clutter: [ClutterFile] = [
        ClutterFile(url: dl.appendingPathComponent("Xcode_13.2.1.dmg"),
                    reason: "Installeur, ouvert il y a 212 j", bytes: 10_900_000_000, preselect: true),
        ClutterFile(url: dl.appendingPathComponent("zoomusInstallerFull.pkg"),
                    reason: "Installeur, ouvert il y a 48 j", bytes: 118_000_000, preselect: true),
        ClutterFile(url: dl.appendingPathComponent("Vacances-2023-export.mov"),
                    reason: "Pas ouvert depuis 301 j", bytes: 2_400_000_000, preselect: false),
        ClutterFile(url: dl.appendingPathComponent("Facture_0412.pdf.command"),
                    reason: "Suspect : double extension : se fait passer pour un PDF",
                    bytes: 12_000, preselect: false)
    ]

    static let dormant: [DormantApp] = [
        DormantApp(url: URL(fileURLWithPath: "/Applications/Skitch.app"), name: "Skitch",
                   bundleID: "com.skitch.skitch",
                   lastUsed: Date().addingTimeInterval(-400 * 86_400),
                   bytes: 61_000_000, fromAppStore: true,
                   leftovers: [lib.appendingPathComponent("Caches/com.skitch.skitch")]),
        DormantApp(url: URL(fileURLWithPath: "/Applications/Old Converter.app"), name: "Old Converter",
                   bundleID: "fr.exemple.converter",
                   lastUsed: Date().addingTimeInterval(-190 * 86_400),
                   bytes: 340_000_000, fromAppStore: false,
                   leftovers: [lib.appendingPathComponent("Application Support/Old Converter"),
                               lib.appendingPathComponent("Preferences/fr.exemple.converter.plist")])
    ]

    // ── Cybersécurité ──
    //  De vrais motifs de fraude, sur des domaines inventés ou réservés.

    static let links: [String] = [
        "https://paypa1-secure-login.xyz/verify?id=88213",
        "http://192.0.2.44/colis/frais-de-douane",
        "https://bit.ly/3xYzBud",
        "https://www.impots.gouv.fr/accueil"
    ]

    static let mails: [MailMessage] = {
        var a = MailMessage(subject: "Votre colis est en attente — frais de douane",
                            sender: "Chronopost <suivi@chrono-livraison.top>", date: "")
        a.snippet = "Votre colis est en attente. Réglez 1,99 € sous 24 heures : https://chrono-livraison.top/payer"
        var b = MailMessage(subject: "Compte rendu de la réunion",
                            sender: "Camille <camille@exemple.fr>", date: "")
        b.snippet = "Bonjour, voici le compte rendu de jeudi. Bonne journée."
        return [a, b]
    }()

    // ── Météo & Maison ──

    static var weather: WeatherReport {
        let now = Date()
        let hours = (0..<12).map {
            WeatherHour(time: now.addingTimeInterval(Double($0) * 3600),
                        temp: 14 - Double($0) * 0.4, code: $0 < 6 ? 0 : 1, isDay: $0 < 6)
        }
        let days = (0..<7).map {
            WeatherDay(date: now.addingTimeInterval(Double($0) * 86_400),
                       code: [0, 1, 2, 61, 3, 0, 1][$0],
                       tmin: [6.0, 5, 7, 8, 6, 3, 4][$0], tmax: [15.0, 13, 12, 11, 12, 10, 11][$0],
                       rain: [0, 0, 10, 70, 30, 0, 0][$0])
        }
        return WeatherReport(place: WeatherPlace(name: "Paris", country: "France",
                                                 latitude: 48.85, longitude: 2.35),
                             fetchedAt: now, temp: 14, feels: 12, code: 0, isDay: true,
                             wind: 9, humidity: 61, hours: hours, days: days)
    }

    static let homeScenes = ["Chauffage salon 20°", "Lumière salon", "Lumières éteintes",
                             "Bonne nuit", "Caméra entrée"]

    // ── Le tour des expressions ──

    static let expressionTour: [BudExpression] = [
        .neutral, .working, .happy, .reflection, .annoyed, .dizzy, .cool, .sad
    ]
}
