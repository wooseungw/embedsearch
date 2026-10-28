// Reproducible, original synthetic regression assets. No personal documents or downloads.
// Usage: arch -arm64 swift tools/eval/make-fixtures.swift build/eval-fixtures
import AppKit
import CoreText
import CryptoKit
import Foundation
import ImageIO

struct Topic {
    let title: String
    let detail: String
    let english: String
    let korean: String
}
let topics: [Topic] = [
    .init(title: "Winter beehive care", detail: "Insulate honeybee colonies before frost. Check stored honey and leave ventilation above the cluster. A winter colony needs food without cold drafts.", english: "keeping honey bees alive through a freezing winter", korean: "겨울에 벌통을 보온하고 꿀벌의 먹이를 관리하는 문서"),
    .init(title: "Rainwater vegetable garden", detail: "Roof gutters fill a rain barrel. Gravity drip irrigation delivers collected water to tomato and lettuce roots. A screen keeps insects out of the storage tank.", english: "using roof runoff to water vegetables with gravity drip lines", korean: "빗물을 모아서 채소밭에 점적 관수하는 방법"),
    .init(title: "Bicycle puncture repair", detail: "Remove the wheel and inner tube. Locate the puncture under water, roughen the rubber and apply a patch. Inspect the tire for glass before reinflating.", english: "patching a punctured bicycle inner tube", korean: "자전거 튜브의 펑크를 찾아 패치로 수리하기"),
    .init(title: "Sourdough starter feeding", detail: "Mix equal weights of flour and water with the retained starter. Mark the jar height and wait for bubbles and doubling. Refrigerate the culture between baking days.", english: "maintaining a bubbling flour and water culture for bread", korean: "빵을 만들기 위해 사워도우 발효종을 먹이고 보관하는 법"),
    .init(title: "Home earthquake supplies", detail: "Store drinking water, canned food, a radio, flashlight and essential medication. Strap heavy furniture to wall studs and identify a family meeting point after an earthquake.", english: "preparing household emergency supplies before an earthquake", korean: "지진에 대비해 집에 물과 비상용품을 준비하는 계획"),
    .init(title: "Coral reef monitoring", detail: "Divers photograph the same underwater transect each month. Record coral bleaching, water temperature and species counts. Compare healthy tissue cover across seasons.", english: "tracking coral bleaching with repeat underwater surveys", korean: "산호 백화 현상을 수온과 수중 사진으로 관찰하는 연구"),
    .init(title: "Library book preservation", detail: "Keep archival books away from direct sunlight. Control humidity and use acid-free boxes. Support fragile bindings during reading and never repair old pages with adhesive tape.", english: "protecting fragile old books from humidity and sunlight", korean: "습기와 햇빛으로부터 오래된 도서를 보존하는 방법"),
    .init(title: "Mountain trail erosion", detail: "Build drainage dips across steep paths. Harden muddy turns with stone and keep hikers on marked routes. Photograph soil loss after heavy rain to assess trail repairs.", english: "preventing rain from washing soil off hiking trails", korean: "등산로의 빗물 배수와 토양 침식을 줄이는 작업"),
    .init(title: "Coffee roasting log", detail: "Record green bean origin, batch mass and drum temperature. Note first crack time and final roast color. Let roasted coffee rest before comparing aroma and acidity.", english: "logging bean temperature and first crack during coffee roasting", korean: "커피 원두 로스팅에서 온도와 첫 크랙을 기록하기"),
    .init(title: "Aquarium nitrogen cycle", detail: "Beneficial bacteria convert fish ammonia to nitrite and then nitrate. Test the water before adding fish. Avoid replacing all filter media at once because it removes the bacterial colony.", english: "cycling a fish tank to remove toxic ammonia", korean: "어항의 암모니아를 줄이는 질소 순환과 여과 박테리아"),
    .init(title: "Rooftop solar inspection", detail: "Inspect solar panel cables and inverter fault indicators. Compare daily electricity output against sunny-day baselines. Clean accumulated leaves without stepping on photovoltaic glass.", english: "checking a rooftop solar inverter when electricity output drops", korean: "옥상 태양광 발전량이 감소했을 때 인버터를 점검하기"),
    .init(title: "Ceramic kiln firing", detail: "Dry clay completely before bisque firing. Raise kiln temperature gradually and use witness cones to measure heat work. Let glazed pottery cool slowly before opening the kiln.", english: "firing glazed pottery safely in a ceramic kiln", korean: "도자기 가마의 온도를 올리고 유약을 소성하는 과정"),
    .init(title: "Urban bat survey", detail: "Record ultrasonic bat calls beside the river after sunset. Match call frequency patterns to local species. Count passes at fixed stations without shining bright lights at roosts.", english: "identifying bats by ultrasonic calls at night", korean: "밤에 초음파 소리를 녹음해 박쥐 종류를 조사하기"),
    .init(title: "Orchard pruning calendar", detail: "Remove crossing apple branches while trees are dormant. Sterilize pruning tools between trees. Thin the canopy to improve airflow while retaining fruiting spurs.", english: "pruning dormant apple trees to improve canopy airflow", korean: "사과나무의 교차 가지를 잘라 과수원의 통풍을 개선하기"),
    .init(title: "Seagrass restoration", detail: "Plant nursery-grown seagrass shoots in shallow coastal sediment. Mark transplant plots and measure survival each month. Protect the plots from boat anchors and sediment disturbance.", english: "restoring coastal seagrass with nursery transplants", korean: "연안 해초를 이식하고 생존율을 추적하는 복원 사업"),
    .init(title: "Wool sweater care", detail: "Hand wash wool garments in cool water with mild detergent. Avoid agitation and sudden temperature changes. Reshape the sweater flat on a towel instead of hanging it to dry.", english: "washing a wool sweater without shrinking its fibers", korean: "울 스웨터가 줄어들지 않도록 손세탁하고 평평하게 말리기"),
    .init(title: "Mushroom cultivation", detail: "Sterilize straw substrate and inoculate it with oyster mushroom spawn. Maintain humidity and fresh air during fruiting. Discard contaminated bags showing green mold.", english: "growing oyster mushrooms in humid straw bags", korean: "짚 배지에서 느타리버섯을 재배하고 오염을 관리하는 법"),
    .init(title: "Telescope collimation", detail: "Align the primary and secondary mirrors of a reflecting telescope. Center the laser spot and inspect a defocused star. Recheck alignment after transporting the optical tube.", english: "aligning mirrors inside a reflecting telescope", korean: "반사 망원경의 주경과 부경을 정렬하는 작업"),
    .init(title: "Coastal tide pool fieldwork", detail: "Visit rocky tide pools near low tide. Identify anemones, limpets and small crabs without removing them. Record water temperature and keep footwear clear of slippery algae.", english: "observing small marine animals in rocky pools at low tide", korean: "썰물 때 조수 웅덩이의 말미잘과 게를 관찰하기"),
    .init(title: "Violin bow maintenance", detail: "Loosen bow hair after practice and wipe rosin dust from the stick. Avoid touching horsehair with oily fingers. Replace worn hair when the bow no longer grips the string evenly.", english: "maintaining violin bow horsehair and removing rosin dust", korean: "바이올린 활털과 송진 가루를 관리하는 방법"),
    .init(title: "Compost pile balance", detail: "Alternate dry brown leaves with nitrogen-rich kitchen scraps. Turn the compost pile to add oxygen and keep it as damp as a wrung sponge. A sour smell indicates poor aeration.", english: "balancing dry leaves and food scraps in an aerated compost pile", korean: "퇴비 더미의 낙엽과 음식물 비율 및 통기를 조절하기"),
    .init(title: "Kayak rescue practice", detail: "Practice a wet exit and assisted re-entry in calm sheltered water. Wear a flotation device and keep a paddle float accessible. Check local wind before leaving the shore.", english: "practicing how to get back into a capsized kayak", korean: "뒤집힌 카약에서 탈출하고 다시 탑승하는 구조 연습"),
    .init(title: "Seed bank storage", detail: "Dry collected native seeds before sealing them in labeled containers. Store the seed bank in cool stable conditions. Test germination from small samples at regular intervals.", english: "drying and storing native plant seeds for long-term conservation", korean: "자생 식물 종자를 건조 보관하고 발아율을 검사하기"),
    .init(title: "Leather shoe conditioning", detail: "Brush dirt off leather shoes and let damp shoes dry naturally. Apply a small amount of conditioner with a soft cloth. Insert cedar shoe trees to preserve shape between wears.", english: "conditioning leather shoes and preserving their shape", korean: "가죽 구두에 컨디셔너를 바르고 형태를 유지하는 관리법"),
    .init(title: "Wetland bird census", detail: "Count waterbirds from fixed observation points at dawn. Use binoculars and record flock size by species. Repeat the survey at the same tidal stage to compare seasonal migration.", english: "counting migrating waterbirds from fixed wetland observation points", korean: "습지에서 철새의 종류와 개체 수를 정기적으로 조사하기"),
    .init(title: "Chocolate tempering", detail: "Melt dark chocolate gently and cool it while stirring. Rewarm to working temperature to form stable cocoa butter crystals. Proper tempering produces a glossy surface and a clean snap.", english: "forming stable cocoa butter crystals for glossy chocolate", korean: "초콜릿 표면을 반짝이게 만드는 템퍼링 온도 조절"),
    .init(title: "Glacier stake measurements", detail: "Measure the exposed height of stakes drilled into glacier ice. Repeat readings through the melt season. Combine ablation records with snowfall measurements to estimate glacier mass balance.", english: "measuring glacier melting with stakes drilled into the ice", korean: "빙하에 박은 말뚝으로 얼음이 녹는 양을 측정하기"),
    .init(title: "Indoor orchid roots", detail: "Grow epiphytic orchids in coarse bark rather than dense potting soil. Water when roots turn silvery and allow complete drainage. Trim rotten roots with sterilized scissors.", english: "caring for orchid roots in a well-drained bark medium", korean: "난초 뿌리를 수피 배지에서 관리하고 과습을 방지하기"),
    .init(title: "Map and compass navigation", detail: "Orient the topographic map to magnetic north. Account for local declination before following a bearing. Identify ridges and stream junctions to confirm location without satellite reception.", english: "finding a route with a compass and topographic map without GPS", korean: "GPS 없이 지형도와 나침반으로 방위와 위치를 확인하기"),
    .init(title: "Rain gauge calibration", detail: "Pour a measured volume of water into the tipping-bucket rain gauge. Count electrical pulses and adjust the bucket stop screws. Clear debris from the funnel before comparing rainfall totals.", english: "calibrating a tipping-bucket rainfall sensor with measured water", korean: "일정량의 물로 전도형 강우량 센서를 교정하는 방법")
]
let root = URL(filePath: CommandLine.arguments.dropFirst().first ?? "build/eval-fixtures", directoryHint: .isDirectory)
let files = root.appending(path: "files", directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
var development: [[String: Any]] = [], validation: [[String: Any]] = [], manifest: [[String: Any]] = []
func text(_ string: String, in context: CGContext, rect: CGRect, size: CGFloat) {
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.black]
    let attributed = NSAttributedString(string: string, attributes: attributes)
    let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attributed), CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
    CTFrameDraw(frame, context)
}
func addQueries(_ values: [(String, String, String)], title: String, heldOut: Bool) {
    for (query, lang, type) in values {
        let row: [String: Any] = ["q": query, "lang": lang, "type": type, "expect": [["kind": "file", "title": title]]]
        if heldOut { validation.append(row) } else { development.append(row) }
    }
}
func record(_ url: URL, split: String) throws {
    let data = try Data(contentsOf: url)
    manifest.append(["file": url.lastPathComponent, "split": split, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()])
}
for (i, topic) in topics.enumerated() {
    let name = String(format: "doc-%02d.pdf", i), identifier = String(format: "FIELDNOTE%04d", 8100 + i)
    let url = files.appending(path: name)
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let pdf = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextTitle: topic.title] as CFDictionary)!
    pdf.beginPDFPage(nil)
    text(topic.title + "\n\n" + topic.detail + "\n\nArchive reference: " + identifier + ".", in: pdf, rect: box.insetBy(dx: 50, dy: 60), size: 16)
    pdf.endPDFPage(); pdf.closePDF()
    let heldOut = i % 3 == 0
    addQueries([(topic.english, "en", "file_paraphrase"), (topic.korean, "ko", "file_crosslang"), (identifier, "en", "file_keyword")], title: name, heldOut: heldOut)
    try record(url, split: heldOut ? "validation" : "development")
}
let labels = ["NORTH HARBOR FERRY", "HIKING CLUB PERMIT", "MUSEUM ADMISSION TICKET", "ORGANIC MARKET RECEIPT", "MARATHON RUNNER BADGE", "ASTRONOMY CAMP PASS", "BOTANICAL GARDEN MAP", "CERAMICS WORKSHOP CARD", "WILDLIFE RESCUE CONTACT", "RAILWAY LUGGAGE TAG"]
let ko = ["북쪽 항구 페리 탑승권 이미지", "등산 동호회 허가증 이미지", "박물관 입장권 이미지", "유기농 시장 영수증 이미지", "마라톤 참가자 이름표 이미지", "천문학 캠프 출입증 이미지", "식물원 안내 지도 이미지", "도자기 공방 수업 카드 이미지", "야생동물 구조 연락처 이미지", "기차 수하물 표찰 이미지"]
for i in labels.indices {
    let name = String(format: "image-%02d.png", i), url = files.appending(path: name)
    let context = CGContext(data: nil, width: 900, height: 500, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 900, height: 500))
    context.setFillColor(NSColor(calibratedHue: CGFloat(i) / 10, saturation: 0.7, brightness: 0.8, alpha: 1).cgColor)
    context.fill(CGRect(x: 40, y: 370, width: 820, height: 60))
    text(labels[i] + "\n\nREFERENCE: VISUAL\(9200 + i)", in: context, rect: CGRect(x: 50, y: 80, width: 800, height: 250), size: 32)
    let output = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(output, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(output))
    let heldOut = i % 3 == 0
    addQueries([(ko[i], "ko", "image_ocr_semantic"), ("VISUAL\(9200 + i)", "en", "image_ocr_keyword")], title: name, heldOut: heldOut)
    try record(url, split: heldOut ? "validation" : "development")
}
validation.append(["q": "zzzxqv9713 nonexistent zephyr archive", "lang": "en", "type": "negative", "expect": [], "expectNone": true])
for (name, rows) in [("development.jsonl", development), ("validation.jsonl", validation)] {
    let data = try rows.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }.reduce(into: Data()) { $0.append($1); $0.append(10) }
    try data.write(to: root.appending(path: name), options: .atomic)
}
let metadata: [String: Any] = ["schemaVersion": 1, "license": "CC0-1.0", "scope": "Original synthetic PDF and OCR regression smoke tests; not a natural-image or user-corpus benchmark.", "splitRule": "Document/image index modulo three; all paraphrases of a file stay in one split.", "files": manifest]
try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: root.appending(path: "manifest.json"), options: .atomic)
print("Generated \(manifest.count) files, \(development.count) development and \(validation.count) validation queries at \(root.path)")
