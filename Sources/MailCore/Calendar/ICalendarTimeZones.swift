import Foundation

extension ICalendar {
    /// IANA zone for a Windows time zone name, as Outlook and Exchange write in TZID:
    /// "Pacific Standard Time" -> "America/Los_Angeles". Case-insensitive; nil for unknown names.
    public static func ianaZone(forWindowsName name: String) -> String? {
        windowsZones[name.trimmingCharacters(in: .whitespaces).lowercased()]
    }

    /// The IANA identifier a TZID means by its name alone: a Windows name, an IANA name (kept as
    /// written), either behind a prefix such as Mozilla's `/mozilla.org/20050126_1/`, or an Outlook
    /// display name such as "(UTC-08:00) Pacific Time (US & Canada)". Nil when the name is unknown.
    static func ianaIdentifier(forTZID tzid: String) -> String? {
        let name = normalizedTZID(tzid)
        // No calendar writes a zone name this long; a hostile file could make the lookups below slow.
        guard !name.isEmpty, name.utf8.count <= longestTZID else { return nil }
        var candidates = [name]
        if name.contains("/") {
            // The name behind a prefix is at most three parts long ("America/Argentina/Buenos_Aires").
            let parts = name.split(separator: "/")
            candidates += stride(from: min(3, parts.count), through: 1, by: -1).map { parts.suffix($0).joined(separator: "/") }
        }
        for candidate in candidates {
            // Windows names first: Foundation also accepts offsets such as "UTC-08", which are not IANA names.
            if let iana = ianaZone(forWindowsName: candidate) { return iana }
            if TimeZone(identifier: candidate) != nil { return candidate }
        }
        return outlookZone(displayName: name)
    }

    /// The longest TZID read as a zone name, in bytes.
    static let longestTZID = 256

    /// A TZID without surrounding whitespace and quotes, the key VTIMEZONE blocks are stored under.
    static func normalizedTZID(_ tzid: String) -> String {
        tzid.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"")))
    }

    /// The zone of an Outlook display name, "(UTC-08:00) Pacific Time (US & Canada)" or the older
    /// "(GMT-08.00) Pacific Time (US & Canada); Tijuana".
    static func outlookZone(displayName: String) -> String? {
        var label = Substring(displayName)
        if label.hasPrefix("("), let close = label.firstIndex(of: ")") { label = label[label.index(after: close)...] }
        let key = label.trimmingCharacters(in: .whitespaces).lowercased()
        if let zone = outlookDisplayNames[key] { return zone }
        guard let place = key.split(separator: ";").first else { return nil }
        return outlookDisplayNames[place.trimmingCharacters(in: .whitespaces)]
    }

    /// Turns TZIDs into zones, remembering each answer for the rest of the file.
    struct ZoneResolver {
        /// A zone to read local times in, and the identifier to store with them (nil for a bare UTC offset).
        struct Resolved {
            var zone: TimeZone
            var identifier: String?

            func date(from parts: DateComponents) -> Date? {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = zone
                return calendar.date(from: parts)
            }
        }

        let definitions: [String: ZoneDefinition]
        let defaultZone: TimeZone
        private var resolved: [String: Resolved] = [:]

        init(definitions: [String: ZoneDefinition], defaultZone: TimeZone) {
            self.definitions = definitions
            self.defaultZone = defaultZone
        }

        /// Floating times: the default zone, stored with its identifier.
        var floating: Resolved { Resolved(zone: defaultZone, identifier: defaultZone.identifier) }

        /// The zone a TZID names: by name (IANA, Windows, Outlook), else by the file's VTIMEZONE block
        /// for it, else the default zone. `year` picks the rules a VTIMEZONE is compared with.
        mutating func zone(forTZID tzid: String, year: Int) -> Resolved {
            if let known = resolved[tzid] { return known }
            let answer = resolve(tzid, year: year)
            resolved[tzid] = answer
            return answer
        }

        private func resolve(_ tzid: String, year: Int) -> Resolved {
            if let identifier = ICalendar.ianaIdentifier(forTZID: tzid), let zone = TimeZone(identifier: identifier) {
                return Resolved(zone: zone, identifier: identifier)
            }
            if let definition = definitions[ICalendar.normalizedTZID(tzid)] {
                if let zone = definition.matchingZone(year: year) { return Resolved(zone: zone, identifier: zone.identifier) }
                if let offset = definition.standardOffset, let zone = TimeZone(secondsFromGMT: offset) {
                    return Resolved(zone: zone, identifier: nil)
                }
            }
            return floating
        }
    }

    /// A VTIMEZONE block: what a TZID means when its name is unknown, as with Outlook's "Customized Time Zone".
    struct ZoneDefinition {
        /// A STANDARD or DAYLIGHT block.
        struct Observance {
            var isDaylight: Bool
            /// DTSTART as written ("19701101T020000"), which sorts by time.
            var start = ""
            /// TZOFFSETTO, in seconds east of UTC.
            var offset: Int?
            /// The month the observance begins: BYMONTH of its yearly rule, else the month of DTSTART.
            var month: Int?

            init(isDaylight: Bool) {
                self.isDaylight = isDaylight
            }

            mutating func read(_ line: ContentLine) {
                let value = line.value.trimmingCharacters(in: .whitespaces)
                switch line.name {
                case "DTSTART":
                    start = value
                    if month == nil { month = ICalendar.number(Array(value.utf8), 4..<6) }
                case "TZOFFSETTO":
                    offset = ICalendar.utcOffset(value)
                case "RRULE":
                    for part in value.uppercased().split(separator: ";") where part.hasPrefix("BYMONTH=") {
                        month = part.dropFirst(8).split(separator: ",").first.flatMap { Int($0) }
                    }
                default:
                    break
                }
            }
        }

        var id = ""
        var observances: [Observance] = []

        /// The offset of the latest STANDARD block, or of the latest DAYLIGHT block when there is none.
        var standardOffset: Int? { latest(isDaylight: false)?.offset ?? latest(isDaylight: true)?.offset }

        private func latest(isDaylight: Bool) -> Observance? {
            observances.filter { $0.isDaylight == isDaylight && $0.offset != nil }.max { $0.start < $1.start }
        }

        /// An IANA zone with this block's offsets in mid-January and mid-July of `year`, with summer time
        /// on the same side of the equator. Candidates come from the Windows table in order, so the common
        /// zone for each pair of offsets wins.
        func matchingZone(year: Int) -> TimeZone? {
            guard let standard = standardOffset else { return nil }
            let daylightBlock = latest(isDaylight: true)
            let daylight = daylightBlock?.offset ?? standard
            // Summer time that begins in the first half of the year is northern.
            let isNorthern = (daylightBlock?.month ?? 1) <= 6
            let (january, july) = isNorthern ? (standard, daylight) : (daylight, standard)
            guard let winter = ICalendar.utcCalendar.date(from: DateComponents(year: year, month: 1, day: 15, hour: 12)),
                  let summer = ICalendar.utcCalendar.date(from: DateComponents(year: year, month: 7, day: 15, hour: 12)) else { return nil }
            for identifier in ICalendar.windowsZoneCandidates {
                guard let zone = TimeZone(identifier: identifier) else { continue }
                if zone.secondsFromGMT(for: winter) == january, zone.secondsFromGMT(for: summer) == july { return zone }
            }
            return nil
        }
    }

    /// "+0530" or "-0800", seconds optional, as seconds east of UTC.
    static func utcOffset(_ text: String) -> Int? {
        let bytes = Array(text.replacingOccurrences(of: ":", with: "").utf8)
        guard bytes.count == 5 || bytes.count == 7, bytes[0] == UInt8(ascii: "+") || bytes[0] == UInt8(ascii: "-"),
              let hours = number(bytes, 1..<3), let minutes = number(bytes, 3..<5),
              let seconds = bytes.count == 7 ? number(bytes, 5..<7) : 0 else { return nil }
        let total = hours * 3600 + minutes * 60 + seconds
        return bytes[0] == UInt8(ascii: "-") ? -total : total
    }
}

// MARK: - Tables

extension ICalendar {
    /// Windows zone names and their IANA zones: CLDR's windowsZones.xml mappings for territory "001",
    /// using current IANA names where CLDR keeps an old one (Asia/Kolkata, Europe/Kyiv), plus names
    /// from older Windows versions. Ordered by region, most common first, because matching a VTIMEZONE
    /// by its offsets takes the first zone that fits.
    static let windowsZoneTable: [(windows: String, iana: String)] = [
        ("UTC", "Etc/UTC"),
        // North America
        ("Pacific Standard Time", "America/Los_Angeles"),
        ("Mountain Standard Time", "America/Denver"),
        ("US Mountain Standard Time", "America/Phoenix"),
        ("Central Standard Time", "America/Chicago"),
        ("Eastern Standard Time", "America/New_York"),
        ("Atlantic Standard Time", "America/Halifax"),
        ("Newfoundland Standard Time", "America/St_Johns"),
        ("Alaskan Standard Time", "America/Anchorage"),
        ("Hawaiian Standard Time", "Pacific/Honolulu"),
        ("Canada Central Standard Time", "America/Regina"),
        ("US Eastern Standard Time", "America/Indiana/Indianapolis"),
        ("British Columbia Standard Time", "America/Vancouver"),
        ("Alberta Standard Time", "America/Edmonton"),
        ("Manitoba Standard Time", "America/Winnipeg"),
        ("Yukon Standard Time", "America/Whitehorse"),
        ("Aleutian Standard Time", "America/Adak"),
        ("Central Standard Time (Mexico)", "America/Mexico_City"),
        ("Pacific Standard Time (Mexico)", "America/Tijuana"),
        ("Mountain Standard Time (Mexico)", "America/Mazatlan"),
        ("Eastern Standard Time (Mexico)", "America/Cancun"),
        ("Central America Standard Time", "America/Guatemala"),
        ("Cuba Standard Time", "America/Havana"),
        ("Haiti Standard Time", "America/Port-au-Prince"),
        ("Turks And Caicos Standard Time", "America/Grand_Turk"),
        ("Saint Pierre Standard Time", "America/Miquelon"),
        ("Greenland Standard Time", "America/Nuuk"),
        // Europe and Africa
        ("GMT Standard Time", "Europe/London"),
        ("W. Europe Standard Time", "Europe/Berlin"),
        ("Romance Standard Time", "Europe/Paris"),
        ("Central Europe Standard Time", "Europe/Budapest"),
        ("Central European Standard Time", "Europe/Warsaw"),
        ("GTB Standard Time", "Europe/Bucharest"),
        ("FLE Standard Time", "Europe/Kyiv"),
        ("E. Europe Standard Time", "Europe/Chisinau"),
        ("Russian Standard Time", "Europe/Moscow"),
        ("Turkey Standard Time", "Europe/Istanbul"),
        ("Belarus Standard Time", "Europe/Minsk"),
        ("Greenwich Standard Time", "Atlantic/Reykjavik"),
        ("Azores Standard Time", "Atlantic/Azores"),
        ("Cape Verde Standard Time", "Atlantic/Cape_Verde"),
        ("W. Central Africa Standard Time", "Africa/Lagos"),
        ("South Africa Standard Time", "Africa/Johannesburg"),
        ("Egypt Standard Time", "Africa/Cairo"),
        ("E. Africa Standard Time", "Africa/Nairobi"),
        ("Morocco Standard Time", "Africa/Casablanca"),
        ("Libya Standard Time", "Africa/Tripoli"),
        ("Namibia Standard Time", "Africa/Windhoek"),
        ("Sudan Standard Time", "Africa/Khartoum"),
        ("South Sudan Standard Time", "Africa/Juba"),
        ("Sao Tome Standard Time", "Africa/Sao_Tome"),
        // Middle East and Asia
        ("Israel Standard Time", "Asia/Jerusalem"),
        ("Arab Standard Time", "Asia/Riyadh"),
        ("Arabian Standard Time", "Asia/Dubai"),
        ("Arabic Standard Time", "Asia/Baghdad"),
        ("Iran Standard Time", "Asia/Tehran"),
        ("Jordan Standard Time", "Asia/Amman"),
        ("Middle East Standard Time", "Asia/Beirut"),
        ("Syria Standard Time", "Asia/Damascus"),
        ("West Bank Standard Time", "Asia/Hebron"),
        ("Azerbaijan Standard Time", "Asia/Baku"),
        ("Georgian Standard Time", "Asia/Tbilisi"),
        ("Caucasus Standard Time", "Asia/Yerevan"),
        ("Mauritius Standard Time", "Indian/Mauritius"),
        ("Afghanistan Standard Time", "Asia/Kabul"),
        ("Pakistan Standard Time", "Asia/Karachi"),
        ("West Asia Standard Time", "Asia/Tashkent"),
        ("Qyzylorda Standard Time", "Asia/Qyzylorda"),
        ("India Standard Time", "Asia/Kolkata"),
        ("Sri Lanka Standard Time", "Asia/Colombo"),
        ("Nepal Standard Time", "Asia/Kathmandu"),
        ("Bangladesh Standard Time", "Asia/Dhaka"),
        ("Central Asia Standard Time", "Asia/Bishkek"),
        ("Myanmar Standard Time", "Asia/Yangon"),
        ("SE Asia Standard Time", "Asia/Bangkok"),
        ("W. Mongolia Standard Time", "Asia/Hovd"),
        ("China Standard Time", "Asia/Shanghai"),
        ("Singapore Standard Time", "Asia/Singapore"),
        ("Taipei Standard Time", "Asia/Taipei"),
        ("Ulaanbaatar Standard Time", "Asia/Ulaanbaatar"),
        ("Tokyo Standard Time", "Asia/Tokyo"),
        ("Korea Standard Time", "Asia/Seoul"),
        ("North Korea Standard Time", "Asia/Pyongyang"),
        // Australia and the Pacific
        ("AUS Eastern Standard Time", "Australia/Sydney"),
        ("E. Australia Standard Time", "Australia/Brisbane"),
        ("Cen. Australia Standard Time", "Australia/Adelaide"),
        ("AUS Central Standard Time", "Australia/Darwin"),
        ("W. Australia Standard Time", "Australia/Perth"),
        ("Tasmania Standard Time", "Australia/Hobart"),
        ("Aus Central W. Standard Time", "Australia/Eucla"),
        ("Lord Howe Standard Time", "Australia/Lord_Howe"),
        ("New Zealand Standard Time", "Pacific/Auckland"),
        ("Chatham Islands Standard Time", "Pacific/Chatham"),
        ("Fiji Standard Time", "Pacific/Fiji"),
        ("Tonga Standard Time", "Pacific/Tongatapu"),
        ("Samoa Standard Time", "Pacific/Apia"),
        ("West Pacific Standard Time", "Pacific/Port_Moresby"),
        ("Central Pacific Standard Time", "Pacific/Guadalcanal"),
        ("Norfolk Standard Time", "Pacific/Norfolk"),
        ("Bougainville Standard Time", "Pacific/Bougainville"),
        ("Line Islands Standard Time", "Pacific/Kiritimati"),
        ("Marquesas Standard Time", "Pacific/Marquesas"),
        ("Easter Island Standard Time", "Pacific/Easter"),
        // South America
        ("E. South America Standard Time", "America/Sao_Paulo"),
        ("Argentina Standard Time", "America/Argentina/Buenos_Aires"),
        ("Pacific SA Standard Time", "America/Santiago"),
        ("SA Pacific Standard Time", "America/Bogota"),
        ("SA Western Standard Time", "America/La_Paz"),
        ("SA Eastern Standard Time", "America/Cayenne"),
        ("Venezuela Standard Time", "America/Caracas"),
        ("Paraguay Standard Time", "America/Asuncion"),
        ("Montevideo Standard Time", "America/Montevideo"),
        ("Central Brazilian Standard Time", "America/Cuiaba"),
        ("Bahia Standard Time", "America/Bahia"),
        ("Tocantins Standard Time", "America/Araguaina"),
        ("Magallanes Standard Time", "America/Punta_Arenas"),
        // Russia beyond Moscow
        ("Kaliningrad Standard Time", "Europe/Kaliningrad"),
        ("Volgograd Standard Time", "Europe/Volgograd"),
        ("Astrakhan Standard Time", "Europe/Astrakhan"),
        ("Saratov Standard Time", "Europe/Saratov"),
        ("Russia Time Zone 3", "Europe/Samara"),
        ("Ekaterinburg Standard Time", "Asia/Yekaterinburg"),
        ("Omsk Standard Time", "Asia/Omsk"),
        ("N. Central Asia Standard Time", "Asia/Novosibirsk"),
        ("North Asia Standard Time", "Asia/Krasnoyarsk"),
        ("Altai Standard Time", "Asia/Barnaul"),
        ("Tomsk Standard Time", "Asia/Tomsk"),
        ("North Asia East Standard Time", "Asia/Irkutsk"),
        ("Transbaikal Standard Time", "Asia/Chita"),
        ("Yakutsk Standard Time", "Asia/Yakutsk"),
        ("Vladivostok Standard Time", "Asia/Vladivostok"),
        ("Magadan Standard Time", "Asia/Magadan"),
        ("Sakhalin Standard Time", "Asia/Sakhalin"),
        ("Russia Time Zone 10", "Asia/Srednekolymsk"),
        ("Russia Time Zone 11", "Asia/Kamchatka"),
        // Fixed offsets
        ("UTC-11", "Etc/GMT+11"),
        ("UTC-09", "Etc/GMT+9"),
        ("UTC-08", "Etc/GMT+8"),
        ("UTC-02", "Etc/GMT+2"),
        ("UTC+12", "Etc/GMT-12"),
        ("UTC+13", "Etc/GMT-13"),
        ("Dateline Standard Time", "Etc/GMT+12"),
        // Older Windows versions
        ("Mexico Standard Time", "America/Mexico_City"),
        ("Mexico Standard Time 2", "America/Chihuahua"),
        ("Mid-Atlantic Standard Time", "Etc/GMT+2"),
        ("Armenian Standard Time", "Asia/Yerevan"),
        ("Kamchatka Standard Time", "Asia/Kamchatka"),
    ]

    /// `windowsZoneTable` by lowercased Windows name.
    static let windowsZones: [String: String] = Dictionary(
        windowsZoneTable.map { ($0.windows.lowercased(), $0.iana) }, uniquingKeysWith: { first, _ in first }
    )

    /// The table's IANA zones without repeats, in table order: the zones a VTIMEZONE is matched against.
    static let windowsZoneCandidates: [String] = {
        var seen: Set<String> = []
        return windowsZoneTable.map(\.iana).filter { seen.insert($0).inserted }
    }()

    /// Outlook display names, lowercased and without their "(UTC-08:00)" prefix, for the common zones.
    static let outlookDisplayNames: [String: String] = [
        "coordinated universal time": "Etc/UTC",
        "international date line west": "Etc/GMT+12",
        "hawaii": "Pacific/Honolulu",
        "alaska": "America/Anchorage",
        "pacific time (us & canada)": "America/Los_Angeles",
        "baja california": "America/Tijuana",
        "arizona": "America/Phoenix",
        "mountain time (us & canada)": "America/Denver",
        "central time (us & canada)": "America/Chicago",
        "saskatchewan": "America/Regina",
        "guadalajara, mexico city, monterrey": "America/Mexico_City",
        "central america": "America/Guatemala",
        "eastern time (us & canada)": "America/New_York",
        "indiana (east)": "America/Indiana/Indianapolis",
        "bogota, lima, quito, rio branco": "America/Bogota",
        "atlantic time (canada)": "America/Halifax",
        "newfoundland": "America/St_Johns",
        "brasilia": "America/Sao_Paulo",
        "city of buenos aires": "America/Argentina/Buenos_Aires",
        "buenos aires": "America/Argentina/Buenos_Aires",
        "santiago": "America/Santiago",
        "dublin, edinburgh, lisbon, london": "Europe/London",
        "greenwich mean time : dublin, edinburgh, lisbon, london": "Europe/London",
        "monrovia, reykjavik": "Atlantic/Reykjavik",
        "amsterdam, berlin, bern, rome, stockholm, vienna": "Europe/Berlin",
        "belgrade, bratislava, budapest, ljubljana, prague": "Europe/Budapest",
        "brussels, copenhagen, madrid, paris": "Europe/Paris",
        "sarajevo, skopje, warsaw, zagreb": "Europe/Warsaw",
        "west central africa": "Africa/Lagos",
        "athens, bucharest": "Europe/Bucharest",
        "athens, bucharest, istanbul": "Europe/Bucharest",
        "cairo": "Africa/Cairo",
        "harare, pretoria": "Africa/Johannesburg",
        "helsinki, kyiv, riga, sofia, tallinn, vilnius": "Europe/Kyiv",
        "helsinki, kiev, riga, sofia, tallinn, vilnius": "Europe/Kyiv",
        "jerusalem": "Asia/Jerusalem",
        "istanbul": "Europe/Istanbul",
        "kuwait, riyadh": "Asia/Riyadh",
        "moscow, st. petersburg": "Europe/Moscow",
        "moscow, st. petersburg, volgograd": "Europe/Moscow",
        "nairobi": "Africa/Nairobi",
        "tehran": "Asia/Tehran",
        "abu dhabi, muscat": "Asia/Dubai",
        "islamabad, karachi": "Asia/Karachi",
        "chennai, kolkata, mumbai, new delhi": "Asia/Kolkata",
        "kathmandu": "Asia/Kathmandu",
        "dhaka": "Asia/Dhaka",
        "bangkok, hanoi, jakarta": "Asia/Bangkok",
        "beijing, chongqing, hong kong, urumqi": "Asia/Shanghai",
        "kuala lumpur, singapore": "Asia/Singapore",
        "perth": "Australia/Perth",
        "taipei": "Asia/Taipei",
        "osaka, sapporo, tokyo": "Asia/Tokyo",
        "seoul": "Asia/Seoul",
        "adelaide": "Australia/Adelaide",
        "darwin": "Australia/Darwin",
        "brisbane": "Australia/Brisbane",
        "canberra, melbourne, sydney": "Australia/Sydney",
        "hobart": "Australia/Hobart",
        "auckland, wellington": "Pacific/Auckland",
        "fiji": "Pacific/Fiji",
    ]
}
