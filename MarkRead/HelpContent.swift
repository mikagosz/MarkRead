import Foundation

/// What the Help window says: each section is a picture of the app with numbered points and the same
/// numbers in the steps next to it. Polish and English side by side; the language follows the Mac's
/// first preferred language, Polish when it is Polish and English otherwise.
nonisolated enum HelpContent {
    /// One text in both languages.
    struct Text: Hashable {
        let pl: String
        let en: String
        var current: String { HelpContent.polish ? pl : en }
    }

    static var polish: Bool { Locale.preferredLanguages.first?.hasPrefix("pl") == true }

    /// Which picture stands next to the section; drawn by the app itself in HelpWindow.swift.
    enum Picture { case window, sidebar, editor, format, links, settings }

    struct Section {
        let title: Text
        let lead: Text
        /// Numbered like the points on the picture: the first step is point 1.
        let steps: [Text]
        /// The longer description, folded under "More".
        let more: Text?
        let picture: Picture
    }

    struct Card {
        let symbol: String
        let title: Text
        let text: Text
    }

    private static func t(_ pl: String, _ en: String) -> Text { Text(pl: pl, en: en) }

    static let menuItem = t("Pomoc MarkRead", "MarkRead Help")
    static let windowTitle = t("MarkRead — Pomoc", "MarkRead — Help")
    static let title = t("Pierwsze kroki z MarkRead", "Getting started with MarkRead")
    static let intro = t("Szybki czytnik i edytor plików Markdown. Plik .md otwiera się od razu sformatowany, łącza działają, a poprawki piszesz w tym samym miejscu.",
                         "A quick reader and editor for Markdown files. A .md file opens formatted straight away, its links work, and you edit it right where you read it.")

    static let sections: [Section] = [
        Section(title: t("Okno MarkRead", "The MarkRead window"),
                lead: t("Po lewej lista notatek, po prawej otwarta notatka — czytasz i piszesz w jednym miejscu.",
                        "The list of notes on the left, the open note on the right — reading and writing happen in one place."),
                steps: [t("Nowa notatka (⌘N): wybierasz nazwę i miejsce, plik powstaje od razu.",
                          "New Note (⌘N): pick a name and a place, and the file is created at once."),
                        t("Lista notatek — przypięte, ostatnie i wybrany folder.", "The note list — pinned, recent and the chosen folder."),
                        t("Notatka sformatowana tak, jak będzie wyglądać.", "The note, formatted the way it reads."),
                        t("Zapisz (⌘S) — aktywny, gdy są niezapisane zmiany.", "Save (⌘S) — active when there are unsaved changes.")],
                more: t("Plik otworzysz też podwójnym kliknięciem w Finderze, upuszczając go na okno albo na ikonę w Docku. MarkRead pokazuje jeden plik naraz; gdy podasz kilka, pierwszy się otwiera, a reszta trafia do przypiętych. Listę chowa ⌃⌘S albo przycisk w pasku okna.",
                       "You can also open a file with a double-click in Finder, by dropping it on the window or on the Dock icon. MarkRead shows one file at a time; hand it several and the first opens while the rest are pinned to the list. ⌃⌘S or the button in the window bar hides the list."),
                picture: .window),
        Section(title: t("Lista notatek", "The note list"),
                lead: t("Trzy części, każda z własnym nagłówkiem: przypięte, ostatnio otwierane i cały folder.",
                        "Three parts, each with its own heading: pinned, opened lately and a whole folder."),
                steps: [t("Filtr — zawęża wszystkie trzy części naraz.", "Filter — narrows all three parts at once."),
                        t("Przypięte: przeciągnij notatki z Findera na listę.", "Pinned: drag notes from Finder onto the list."),
                        t("Ostatnie — notatki otwierane wcześniej, najnowsza na górze.", "Recent — notes opened before, newest on top."),
                        t("Folder (⇧⌘O): każdy plik .md w środku, także w podfolderach.", "A folder (⇧⌘O): every .md file inside it, subfolders too.")],
                more: t("Prawy przycisk na notatce przypina ją, usuwa z listy albo pokazuje w Finderze; na pustym miejscu listy otwiera notatkę albo folder. Folder pamiętany jest między uruchomieniami, a „Zamknij folder” go odpina. Notatka, której nie ma na miejscu (np. dysk odłączony), zostaje na liście przygaszona, ze znakiem zapytania.",
                       "Right-click a note to pin it, remove it from the list or show it in Finder; right-click an empty part of the list to open a note or a folder. The folder is remembered between launches, and Close Folder lets go of it. A note that is not where it was (say, a disk is unplugged) stays on the list, dimmed, with a question mark."),
                picture: .sidebar),
        Section(title: t("Czytanie i pisanie", "Reading and writing"),
                lead: t("To, co widzisz, jest plikiem. Znaczniki Markdownu chowają się, gdy kursor stoi w innej linii, i wracają, gdy w nią wejdziesz.",
                        "What you see is the file. Markdown marks hide while the caret is on another line and come back when you step into it."),
                steps: [t("Nagłówki, pogrubienia i kod mają swój styl, bez znaczków # i *.", "Headings, bold and code are styled, without the # and * marks."),
                        t("Listy zadań, cytaty i ramki z Obsidiana.", "Task lists, quotes and Obsidian callouts."),
                        t("Tabele w zamkniętej ramce; kursor w tabeli pokazuje jej surowy tekst.",
                          "Tables in a closed frame; with the caret inside, the table shows its plain text.")],
                more: t("MarkRead niczego nie przepisuje: zapis zmienia tylko to, co napisałeś, a reszta pliku zostaje bajt w bajt — także znaki, których program nie rozumie. Plik w innym kodowaniu niż UTF-8 zostaje w swoim kodowaniu; jeśli dopiszesz znak, którego to kodowanie nie zmieści, program zapyta, zanim zapisze plik jako UTF-8.",
                       "MarkRead rewrites nothing: saving changes only what you typed, and the rest of the file stays byte for byte — even what the app does not understand. A file in an encoding other than UTF-8 keeps its encoding; if you type a character that encoding cannot hold, the app asks before saving the file as UTF-8."),
                picture: .editor),
        Section(title: t("Menu Format", "The Format menu"),
                lead: t("Skróty wstawiają znaczniki Markdownu wokół zaznaczenia albo na początku linii.",
                        "The shortcuts put Markdown marks around the selection or at the start of the line."),
                steps: [t("Pogrubienie, kursywa, przekreślenie, wyróżnienie i kod.", "Bold, italic, strikethrough, highlight and code."),
                        t("Nagłówki 1–3 i zwykły tekst: ⌃⌘1…⌃⌘0.", "Headings 1–3 and body text: ⌃⌘1…⌃⌘0."),
                        t("Lista, zadanie, cytat i blok kodu.", "A list, a task, a quote and a code block."),
                        t("Łącze (⌘K).", "A link (⌘K).")],
                more: nil,
                picture: .format),
        Section(title: t("Łącza", "Links"),
                lead: t("Łącza działają po zwykłym kliknięciu, także [[łącza wiki]] z Obsidiana. Zanim klikniesz, na dole okna widać, dokąd prowadzą.",
                        "Links open with a plain click, Obsidian's [[wiki links]] too. Before you click, the bottom of the window says where they go."),
                steps: [t("Łącze w tekście — adres jest schowany, zostaje sam opis.", "A link in the text — its address is hidden, only the words show."),
                        t("Cel łącza pod wskaźnikiem.", "Where the link under the pointer goes.")],
                more: t("Łącze wiki szuka notatki w folderze z listy, a gdy folderu nie ma — obok otwartej notatki. Ścieżka względna liczy się od otwartego pliku. Strony www i poczta otwierają się od razu; nieznany rodzaj łącza najpierw pyta, pokazując cały adres. Program nigdy nie uruchamia aplikacji ani skryptów z łącza — pokazuje je w Finderze. ⌥-kliknięcie stawia kursor w łączu, żeby poprawić jego tekst.",
                       "A wiki link looks for the note in the folder on the list, and with no folder open, next to the open note. A relative path counts from the open file. Web pages and mail open straight away; an unknown kind of link asks first, showing the whole address. The app never runs an application or a script from a link — it shows them in Finder instead. ⌥-click puts the caret in a link so you can edit its words."),
                picture: .links),
        Section(title: t("Wygląd", "Appearance"),
                lead: t("Plik Markdown nie zapisuje własnego wyglądu — każdy program go wymyśla. Tu wybierasz, jak ma wyglądać w MarkRead (⌘,).",
                        "A Markdown file stores no look of its own — every program invents one. Here you pick the one MarkRead uses (⌘,)."),
                steps: [t("Jeden z czterech wyglądów: MarkRead, jak Xcode, zwykły albo ciemny Claude.",
                          "One of four looks: MarkRead, like Xcode, plain or dark Claude."),
                        t("Czcionka tekstu i jej wielkość.", "The text font and its size."),
                        t("Czcionka kodu — tylko o stałej szerokości znaków.", "The code font — fixed-pitch faces only.")],
                more: t("Kod, wiersze tabel i nagłówek pliku (front matter) są pisane czcionką kodu. Do wyboru są tylko czcionki o stałej szerokości, bo tabela pokazana jako surowy tekst jest wyrównana spacjami. „Przywróć domyślne” wraca do czcionek systemu.",
                       "Code, table rows and front matter are set in the code font. Only fixed-pitch faces are offered, because a table shown as raw text is lined up with spaces. Restore Defaults goes back to the system fonts."),
                picture: .settings),
    ]

    static let goodToKnow = t("Dobrze wiedzieć", "Good to know")
    static let cards: [Card] = [
        Card(symbol: "doc.text", title: t("Zwykłe pliki", "Plain files"),
             text: t("Bez bazy danych i bez konta. Plik .md zostaje plikiem .md — otworzysz go czymkolwiek.",
                     "No database and no account. A .md file stays a .md file, readable by anything.")),
        Card(symbol: "exclamationmark.arrow.circlepath", title: t("Zmiany z zewnątrz", "Changes from elsewhere"),
             text: t("Jeśli plik zmienił się na dysku, MarkRead zapyta przed zapisem: nadpisać czy wczytać na nowo. Plik → Wczytaj z dysku robi to od ręki.",
                     "If the file changed on disk, MarkRead asks before saving: overwrite, or reload. File → Reload from Disk does it at once.")),
        Card(symbol: "square.and.arrow.down", title: t("Niezapisane zmiany", "Unsaved changes"),
             text: t("Przed otwarciem innej notatki albo zamknięciem programu MarkRead zapyta o zapis — nic nie ginie po cichu.",
                     "Before another note opens or the app quits, MarkRead asks about saving — nothing is lost quietly.")),
        Card(symbol: "arrow.down.circle", title: t("Aktualizacje", "Updates"),
             text: t("Raz w miesiącu program pyta fractal8.eu o numer najnowszej wersji i nic więcej nie wysyła. Instaluje dopiero po kliknięciu „Zainstaluj”.",
                     "Once a month the app asks fractal8.eu for the newest version number and sends nothing else. It installs only when you click Install.")),
    ]

    static let more = t("Więcej", "More")
    static let less = t("Mniej", "Less")
    /// The line under the Fractal 8 Dev signature — the same as under the title on fractal8.eu.
    static let signatureLine = t("Natywne programy dla macOS, budowane według jednego wzoru.",
                                 "Native macOS software, built to a single pattern.")

    /// Every text of the window, for the check that none is missing a language.
    static var allTexts: [Text] {
        var all = [menuItem, windowTitle, title, intro, goodToKnow, more, less, signatureLine]
        for s in sections { all += [s.title, s.lead] + s.steps + (s.more.map { [$0] } ?? []) }
        for c in cards { all += [c.title, c.text] }
        return all
    }
}
