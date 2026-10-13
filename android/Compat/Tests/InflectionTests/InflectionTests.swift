import Testing

/// Every counted phrase in the catalog, as its English key and Spanish translation format it,
/// read through `AndroidInflection` the way the Android build resolves it.
@Suite("AndroidInflection")
struct AndroidInflectionTests {
    @Test(arguments: [
        ("^[2 dose](inflect: true)", "2 doses"),
        ("^[2 staged dose](inflect: true)", "2 staged doses"),
        ("A meal delays ^[3 dose](inflect: true) by up to ~1h", "A meal delays 3 doses by up to ~1h"),
        ("^[2 entry](inflect: true)", "2 entries"),
        ("^[2 entry](inflect: true) syncing", "2 entries syncing"),
        ("^[4 group](inflect: true)", "4 groups"),
        ("^[2 interaction](inflect: true) detected", "2 interactions detected"),
        ("^[2 item](inflect: true), all logged today", "2 items, all logged today"),
        ("Log ^[3 Item](inflect: true)", "Log 3 Items"),
        ("^[5 more combination](inflect: true)", "5 more combinations"),
        ("^[2 other substance](inflect: true)", "2 other substances"),
        ("^[12 substance](inflect: true)", "12 substances"),
        ("^[0 tag](inflect: true)", "0 tags"),
    ])
    func `English phrases take the plural for every count but one`(_ text: String, _ expected: String) {
        #expect(AndroidInflection.resolve(text, language: "en-US") == expected)
    }

    @Test(arguments: [
        ("^[2 dosis](inflect: true)", "2 dosis"),
        ("^[2 dosis preparada](inflect: true)", "2 dosis preparadas"),
        ("Una comida retrasa ^[3 dosis](inflect: true) hasta ~1 h", "Una comida retrasa 3 dosis hasta ~1 h"),
        ("^[2 registro](inflect: true)", "2 registros"),
        ("Sincronizando ^[2 registro](inflect: true)", "Sincronizando 2 registros"),
        ("^[4 grupo](inflect: true)", "4 grupos"),
        ("^[2 interacción detectada](inflect: true)", "2 interacciones detectadas"),
        ("^[2 elemento](inflect: true), todo registrado hoy", "2 elementos, todo registrado hoy"),
        ("Registrar ^[3 elemento](inflect: true)", "Registrar 3 elementos"),
        ("^[5 combinación más](inflect: true)", "5 combinaciones más"),
        ("^[2 sustancia más](inflect: true)", "2 sustancias más"),
        ("^[12 sustancia](inflect: true)", "12 sustancias"),
        ("^[0 etiqueta](inflect: true)", "0 etiquetas"),
    ])
    func `Spanish phrases agree in number, adjectives included`(_ text: String, _ expected: String) {
        #expect(AndroidInflection.resolve(text, language: "es-419") == expected)
    }

    @Test
    func `A count of one leaves the phrase as written`() {
        #expect(AndroidInflection.resolve("^[1 dose](inflect: true)", language: "en") == "1 dose")
        #expect(AndroidInflection.resolve("^[1 interacción detectada](inflect: true)", language: "es") == "1 interacción detectada")
    }

    @Test
    func `Chinese text and runs without inflection lose only the markup`() {
        #expect(AndroidInflection.resolve("2 份剂量", language: "zh-Hans") == "2 份剂量")
        #expect(AndroidInflection.resolve("^[2 dose](morphology: {number: \"one\"})", language: "en") == "2 dose")
        #expect(AndroidInflection.resolve("no count ^[here](inflect: true)", language: "en") == "no count here")
        #expect(AndroidInflection.resolve("unclosed ^[2 dose", language: "en") == "unclosed ^[2 dose")
    }

    @Test
    func `The phrase ends at its first preposition`() {
        #expect(AndroidInflection.resolve("^[2 dose of caffeine](inflect: true)", language: "en") == "2 doses of caffeine")
        #expect(AndroidInflection.resolve("^[2 dosis de carga](inflect: true)", language: "es") == "2 dosis de carga")
    }

    @Test(arguments: [
        ("box", "boxes"), ("batch", "batches"), ("day", "days"), ("study", "studies"),
        ("child", "children"), ("series", "series"),
    ])
    func `English plural rules`(_ word: String, _ plural: String) {
        #expect(AndroidInflection.englishPlural(word) == plural)
    }

    @Test(arguments: [
        ("examen", "exámenes"), ("volumen", "volúmenes"), ("vez", "veces"), ("mes", "meses"),
        ("autobús", "autobuses"), ("país", "países"), ("análisis", "análisis"), ("ley", "leyes"),
        ("café", "cafés"), ("papel", "papeles"), ("camión", "camiones"),
    ])
    func `Spanish plural rules`(_ word: String, _ plural: String) {
        #expect(AndroidInflection.spanishPlural(word) == plural)
    }
}
