import Cocoa

// Point d'entrée : avec plusieurs fichiers, le code au niveau racine
// doit obligatoirement se trouver dans un fichier nommé main.swift.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let budDelegate = BudDelegate()
app.delegate = budDelegate
app.run()
