# Tính năng của SuZu Media Utils (v0.6.3)

Ứng dụng macOS cho SuZu Media: nhận diện và nhóm khuôn mặt trong ảnh/video sự kiện, cùng các công cụ xử lý ảnh
hàng loạt. Chạy hoàn toàn trên máy (trừ tra cứu người nổi tiếng qua Amazon, nếu bật).

## Dự án và thư mục

| Tính năng | Mô tả ngắn |
|---|---|
| Dự án (Project) | Mỗi sự kiện là một dự án gồm nhiều thư mục; chuyển dự án ở đầu thanh bên (⇧⌘N để tạo mới). |
| Làm việc theo dự án | Người, tìm kiếm, album, quy tắc tự động, xuất file, gallery và công cụ hàng loạt chỉ hiển thị dữ liệu của dự án đang mở. |
| Tất cả dự án | Xem gộp mọi dự án cùng lúc. |
| Nguồn NAS / ổ ngoài / ổ trong | Thêm thư mục từ NAS (SMB), ổ cứng ngoài hoặc ổ máy; NAS kiểm tra mỗi 5 giây, ổ trong theo dõi tức thì. |
| Theo dõi file mới | File mới chép vào được xử lý ngay khi chép xong; file đang chép dở sẽ được chờ. |
| Chuyển thư mục giữa dự án | Chuột phải thư mục → Move to Project, không cần quét lại. |
| Chống trùng thư mục | Một thư mục chỉ thuộc một dự án; từ chối thư mục lồng nhau (tránh đếm file hai lần). |
| Theo dõi theo nội dung | Đổi tên, di chuyển trong Finder hoặc chép trùng không làm mất tên người và không xử lý lại. |
| Tìm lại thư mục | Cả thư mục sự kiện bị đổi tên hay di chuyển: chuột phải → Locate Folder… (hoặc thêm lại thư mục), giữ nguyên mọi khuôn mặt và tên. |
| Duyệt file (Files) | Màn hình mặc định, như Finder: xem mọi ảnh/video trong thư mục của dự án theo từng thư mục con, dạng biểu tượng hoặc danh sách (tên, người trong ảnh, ngày chụp, dung lượng, loại); lọc ảnh/video, xem cả thư mục con, tìm theo tên file hoặc tên người, Space để Quick Look, nhấp đúp để mở, xuất các file đã chọn. |
| Chấm điểm, nhãn màu, chọn/loại | Phím như Lightroom: 0–5 sao, 6–9 nhãn màu (đỏ, vàng, xanh lá, xanh dương), P chọn, X loại, U bỏ cờ; lọc theo sao, cờ (chỉ ảnh chọn, ẩn ảnh loại…) và nhãn. Lưu trong thư viện, không đụng tới file. |
| Ghi điểm vào file | "Write Ratings & Labels to Files…" ghi sao và nhãn vào XMP của ảnh JPEG/HEIC/PNG/TIFF gốc để Lightroom, Bridge, Photo Mechanic đọc được (ảnh loại ghi là −1); điểm ảnh không đổi, thư viện vẫn giữ nguyên khuôn mặt và tên. |
| Lọc ảnh toàn màn hình (Cull) | Nút Cull hoặc phím F: xem từng ảnh toàn màn hình, ← → để chuyển, chấm điểm bằng phím, tự sang ảnh kế. Khung và tên từng khuôn mặt, dải ảnh cắt khuôn mặt ở độ phân giải gốc để kiểm tra nét và mắt, Z để phóng 100% vào khuôn mặt. |
| Cảnh báo nhắm mắt / mờ | Ảnh có khuôn mặt chính nhắm mắt hoặc không nét được đánh dấu; một lệnh loại tất cả các ảnh đó cùng lúc. |
| Lọc theo người | Thanh khuôn mặt phía trên: bấm một hoặc nhiều người để chỉ hiện ảnh có tất cả họ, trong thư mục đang xem và thư mục con. |

## Nhận diện và nhóm khuôn mặt

| Tính năng | Mô tả ngắn |
|---|---|
| Nhận diện khuôn mặt | Tìm mọi khuôn mặt trong ảnh (JPEG, HEIC, PNG, TIFF) và video, bằng Apple Vision + mô hình ArcFace. |
| Hỗ trợ video | MP4/MOV sẵn có; AV1, WebM, MKV, AVI… qua ffmpeg. Lấy 1 khung hình/giây, mỗi người tính một lần mỗi video. |
| Tự động nhóm | Các khuôn mặt giống nhau tự gom thành một người. |
| Đặt tên một lần | Người được dùng chung giữa các dự án: đã đặt tên ở sự kiện trước thì sự kiện sau tự nhận ra. |
| Gợi ý tên | Khi gõ tên sẽ gợi ý những người đã đặt tên trước đó. |
| Một tên, một người | Tên trùng (khác hoa/thường hoặc kiểu mã hóa Unicode) luôn là cùng một người; "New Person…" với tên đã có sẽ gộp vào người đó. |
| "Đây là…" (This Is…) | Gộp một nhóm vào một người đã có tên, ở dự án này hoặc dự án khác. |
| Đặt tên ngay trên lưới | Bấm vào tên để sửa, Enter để lưu và chuyển sang nhóm chưa có tên tiếp theo. |
| Gộp nhóm | Chọn nhiều nhóm (⌘-click) rồi gộp làm một. |
| Sửa nhầm lẫn | "Không phải người này" (không tự gán lại), "Chuyển sang…" người khác hoặc người mới. |
| Khuôn mặt chưa gán | Danh sách khuôn mặt rõ nét chưa thuộc nhóm nào để đặt tên thủ công. Chuột phải lên khuôn mặt (hoặc ⌘-click chọn nhiều): "New Person…" để đặt tên người mới, "Move to" để chuyển vào người đã có tên. |
| Thư mục người quen (Known People) | Thư mục `<Tên>/<ảnh>` giúp tự đặt tên các nhóm khớp, không cần mạng. |
| Gợi ý tên người nổi tiếng | Tra cứu nhóm chưa tên qua Amazon Rekognition (tùy chọn, chỉ gửi ảnh cắt khuôn mặt). |
| Cũng có trong… | Trang người hiển thị các dự án khác mà người đó xuất hiện. |

## Ảnh đẹp nhất và xem ảnh

| Tính năng | Mô tả ngắn |
|---|---|
| Chấm điểm ảnh | Mỗi khuôn mặt được chấm theo chất lượng, độ nét, mắt mở, góc mặt, nụ cười, kích thước. |
| Ảnh đại diện | Tự chọn ảnh đẹp nhất (nét, mở mắt, nhìn thẳng) hoặc chọn thủ công bất kỳ ảnh nào. |
| Trang người | Tab Ảnh / Video / Khuôn mặt; sắp xếp Đẹp nhất, Theo giờ, Theo tên; xem Top 10/20/50/100. |
| Ẩn ảnh chụp liên tiếp | Chỉ giữ ảnh đẹp nhất trong mỗi loạt ảnh gần giống nhau (burst). |
| Lọc "Cùng với…" | Chỉ hiện ảnh có người này chụp chung với người khác. |
| Phát video | Ô video có nút phát và mốc thời gian người đó xuất hiện. |

## Phiên trong sự kiện (Sessions)

| Tính năng | Mô tả ngắn |
|---|---|
| Tự chia phiên | Tự tách sự kiện thành các phiên (khai mạc, trận đấu, trao giải…) ở chỗ ngừng chụp 30 phút (chỉnh được 10–120 phút). |
| Lọc người theo phiên | Bấm một phiên trên trang People để chỉ xem ai có mặt và số ảnh trong phiên đó. |
| Đặt tên phiên | Chuột phải → Rename Session (vd. "Trao giải"); tên giữ nguyên khi có thêm file. |
| Phiên áp dụng mọi nơi | Trang người, khuôn mặt chưa gán, tìm kiếm, Copy/Move và Batch Export đều theo phiên đang chọn. |

## Tìm kiếm và album

| Tính năng | Mô tả ngắn |
|---|---|
| Tìm kiếm | Theo người (tất cả cùng lúc / bất kỳ), ảnh đơn hoặc ảnh nhóm, ảnh/video, ngày, thư mục, phiên. |
| Chỉ ảnh đẹp | Lọc chỉ những ảnh có điểm cao; ẩn ảnh gần giống nhau. |
| Album thông minh | Lưu một tìm kiếm thành album, tự cập nhật khi có file mới. |

## Xuất và chia sẻ

| Tính năng | Mô tả ngắn |
|---|---|
| Chép / chuyển theo người | Đưa ảnh/video của một người vào thư mục mang tên họ (`<thư mục>/<Tên>/`). |
| Xuất tất cả | Chép hoặc chuyển mọi người có tên vào thư mục riêng một lần; ảnh nhóm chuyển cho người lớn nhất trong ảnh và chép cho những người còn lại. |
| Không ghi đè | Bỏ qua file đã có hoặc giữ cả hai (thêm " (2)"). |
| Ghi tên vào file | Ghi tên người vào metadata (IPTC/XMP) để Lightroom, Photo Mechanic, Bridge, Photos đọc được. |
| Top N và bỏ ảnh trùng | Chỉ xuất N ảnh đẹp nhất mỗi người và ảnh đẹp nhất mỗi loạt. |
| Quy tắc tự động (Auto Rules) | Khi có file mới khớp điều kiện kiểu album thông minh (ảnh của một người, mọi người có tên, ảnh đơn đẹp nhất của bất kỳ ai, ảnh nhóm, chỉ ảnh/chỉ video…), tự chép vào thư mục (NAS, Google Drive, Dropbox) — mỗi người một thư mục hoặc tất cả vào một thư mục — có thể kèm cân chỉnh thẳng, auto tone, cắt, watermark, đổi cỡ, ghi tên vào metadata, và báo trên Mac. Sửa quy tắc bất kỳ lúc nào. Thư mục đích chưa gắn hoặc lỗi chép thì tự thử lại sau. |

## Nhóm làm việc (Team) — nhiều máy, một sự kiện

| Tính năng | Mô tả ngắn |
|---|---|
| Chia sẻ dự án qua thư mục | File → Share Project with Team…: chọn một thư mục mọi máy đều mở được (share NAS, Dropbox, iCloud Drive). Không cần tài khoản hay máy chủ. |
| Tham gia nhóm | Trên máy khác: File → Join a Team…, chọn đúng thư mục đó, rồi thêm thư mục ảnh của mình vào dự án. |
| Nhận diện chung | Đặt tên một người trên máy nào thì mọi máy trong nhóm đều nhận ra người đó (kể cả máy của người khác) trong vài giây. |
| Dữ liệu được chia sẻ | Tên người, gộp người, tên phiên và quy tắc tự động. Ảnh, khuôn mặt và ảnh cắt vẫn ở máy nào xử lý máy đó. |
| Làm việc cùng lúc | Mỗi máy ghi vào nhật ký riêng của mình trong thư mục và đọc của máy khác, nên nhiều máy chạy cùng lúc không đụng nhau; máy mất mạng sẽ tự bắt kịp khi có lại. |
| Thay đổi mới nhất thắng | Hai máy cùng sửa tên: tên sửa sau thắng. Cùng một tên đặt trên hai máy thì gộp thành một người. |
| Trạng thái nhóm | Thanh bên hiện tên nhóm, số máy, lần đồng bộ gần nhất; thư mục không truy cập được thì báo và tự tiếp tục khi có lại. Sync Now, mở thư mục nhóm, Leave Team (giữ tên người). |
| Đổi địa chỉ thư mục nhóm | NAS đổi địa chỉ hoặc share gắn tên khác: Locate Team Folder… trỏ nhóm sang chỗ mới của cùng thư mục, không mất gì. |
| Người quen đi theo mọi sự kiện | Mọi người có tên trên một máy (thư mục Known People chuẩn bị trước sự kiện, người từ các sự kiện trước) đều được chia sẻ với nhóm, nên mỗi sự kiện một thư mục nhóm là đủ và máy mới tham gia biết hết. |
| Cập nhật tự động | Ứng dụng tự kiểm tra bản mới mỗi ngày (Settings → Updates, hoặc menu SuZu Media Utils → Check for Updates…) và cài bằng một cú bấm. Cài lần đầu bằng file .dmg (kéo vào Applications). |
| Quy tắc chạy trên mọi máy | Quy tắc tự động của dự án chia sẻ chạy trên từng máy với các file máy đó xử lý. Thư mục đích nên là đường dẫn giống nhau trên mọi máy (cùng share NAS). |
| Khoảnh khắc video | Mỗi người: cắt từng đoạn xuất hiện (không nén lại), dựng video highlight, hoặc xuất khung hình đẹp nhất. |
| Web gallery tĩnh | Xuất thư mục gallery có index.html, mở bằng trình duyệt hoặc chia sẻ qua Drive/NAS. |
| Gallery trong mạng nội bộ | Chia sẻ gallery qua link bí mật trong mạng LAN để xem, phát video, tải ảnh gốc và đặt tên từ iPad, điện thoại. Chỉ truy cập được ảnh của dự án đang mở. |

## Chỉnh sửa ảnh

| Tính năng | Mô tả ngắn |
|---|---|
| Tự động cân màu | Tự chỉnh phơi sáng, tương phản, vùng sáng/tối, màu da; chỉnh được độ mạnh. Tự bật khi cắt khung hoặc đóng watermark. |
| Làm thẳng ảnh nghiêng | Ô "Straighten tilted photos" (phần Look): tự xoay ảnh nghiêng 0,3°–10° theo các đường thẳng đứng (cột, khung cửa, cạnh màn hình, băng rôn) rồi cắt bỏ góc trống. Chỉ xoay khi nhiều đường thẳng cùng chỉ một góc (thử trên ảnh sự kiện xoay ±3°: sai lệch tối đa 0,2°); ảnh không đủ đường thẳng thì giữ nguyên. Nút "Level" trên ảnh xem trước: thanh trượt xoay tay từng ảnh (±10°, bước 0,1°), "Automatic" hoặc "Not Turned". |
| Cắt khung mạng xã hội | 1:1, 4:5, 9:16, 16:9, 1.91:1; giữ mọi người trong ảnh vào khung (người gần người chính trước, bỏ qua người nhỏ ở hậu cảnh). |
| Cắt khung theo hướng ảnh | Bấm một khung để áp dụng cho mọi ảnh; ⌘-click khung thứ hai, vd. 4:5 và 16:9: ảnh dọc cắt 4:5, ảnh ngang (và vuông) cắt 16:9, tự nhận biết từng ảnh. Chọn một khung + "Original" để chỉ cắt một loại, loại kia giữ khung gốc. Chọn một khung thì áp dụng cho mọi ảnh như trước. Mũi tên cạnh nút Export → "Export Each Photo in Both Shapes": mỗi ảnh xuất cả hai khung (tên file thêm "_4x5", "_16x9"). |
| Chỉnh vị trí cắt bằng tay | Kéo ảnh trong khung xem trước để đặt vị trí cắt; ghi nhớ theo từng ảnh, dùng cho mọi khung và mọi màn hình xuất. Nút "Reset crop" để quay lại tự động. |
| Khung riêng cho từng ảnh | Menu "Crop" góc trên bên trái ảnh xem trước: chọn khung riêng cho ảnh đó (hoặc "Same as the others"). Ảnh đã chỉnh có biểu tượng khung cắt trên ảnh nhỏ. |
| Không xuất trùng | Ghi nhớ ảnh nào đã xuất ra file nào (dấu ✓ xanh trên ảnh nhỏ, ngày xuất ở thanh thông tin). Khi xuất lại vào cùng thư mục, hỏi từng ảnh: Skip / Overwrite, có ô "Apply to all". Không bao giờ ghi đè ảnh gốc; hai ảnh khác nhau trùng tên vẫn được thêm " (2)". |
| Watermark logo hoặc chữ | Logo PNG hoặc dòng chữ (vd. "© SuZu Media") có bóng đổ; chỉnh vị trí, kích thước, độ mờ, khoảng cách lề. |
| Watermark dạng banner | Thanh ngang trải hết chiều rộng ảnh (trên, giữa hoặc dưới); một ảnh banner cho ảnh ngang, một cho ảnh dọc, tự chọn theo hướng ảnh. Đặt chiều cao banner (mặc định 112 px trên ảnh cạnh dài 2048 px, tính theo cạnh dài) nên ảnh ngang hay dọc, khung nào cũng cao như nhau; banner được căn giữa, hai bên dư được cắt bỏ (banner hẹp hơn ảnh thì được kéo giãn ngang, chiều cao không đổi). Làm banner rộng hơn ảnh một chút và để chữ, logo ở vùng an toàn giữa banner. |
| Mẫu watermark (preset) | Lưu nhiều mẫu trong Settings → Watermarks; mỗi màn hình chọn và chỉnh mẫu riêng, lưu lại hoặc lưu thành mẫu mới. |
| Căn vị trí watermark | Lưới 3×3 hoặc bấm thẳng lên ảnh xem trước để đặt watermark. |
| Nhớ cài đặt theo màn hình | Mỗi màn hình (Batch Export, Copy/Move, quy tắc tự động, gallery, ảnh từ video) nhớ cài đặt chỉnh sửa riêng. |
| Xem trước lớn | Ảnh xem trước lớn, so sánh trước/sau, hiện kích thước đầu ra, dải ảnh thu nhỏ để chọn ảnh khác. |
| Thay đổi kích thước | Cạnh dài 1080–3000 px hoặc kích thước gốc. Khi cắt khung, mặc định cạnh dài 2048 px (Facebook hiển thị tới 2048 px mà không thu nhỏ); vẫn chọn được cỡ riêng của từng nền tảng (vd. 1350 px cho Instagram 4:5). Giữ khung gốc thì giữ kích thước gốc. |
| Xuất JPEG hoặc PNG | JPEG chỉnh được chất lượng; PNG không nén mất dữ liệu, giữ không gian màu gốc, 16-bit nếu ảnh gốc sâu hơn 8-bit. |

## Công cụ hàng loạt

| Tính năng | Mô tả ngắn |
|---|---|
| Mở để chỉnh & xuất | Chuột phải → Open trên ảnh ở mọi màn hình (People, khuôn mặt, khuôn mặt chưa gán, tìm kiếm, smart album) mở cửa sổ "Edit & Export" giống Batch Export với đúng ảnh đó; ⌘-click chọn nhiều ảnh rồi Open để mở tất cả. Video mở bằng ứng dụng mặc định. |
| Batch Export | Cân màu, cắt khung, watermark, đổi kích thước cho file/thư mục hoặc ảnh của những người đã chọn. Không bao giờ ghi đè: tên đã có thì thêm " (2)". |
| Chọn ảnh để xuất | Tích/bỏ tích từng ảnh trên dải ảnh hoặc lưới (⇧-click chọn dải, Chọn tất cả / Bỏ chọn tất cả). |
| Nguồn là người | Batch Export, Batch Rename, Video Tools nhận đầu vào là người: N ảnh đẹp nhất, bỏ ảnh trùng, mỗi người một thư mục. |
| Batch Rename | Đổi tên theo mẫu `{event} {date} {time} {person} {people} {folder} {seq}` có xem trước; thư viện tự cập nhật đường dẫn. |
| Copy Verifier | So sánh thư mục gốc và bản sao (mặc định so cả nội dung bằng SHA-256), tìm file thiếu hoặc lỗi và sửa lại; bản sửa được kiểm tra trước khi thay bản hỏng. |
| Video Tools | Tạo bản proxy 720p và contact sheet (lưới khung hình có mốc thời gian) cho nhiều video. |

## Hiệu năng và hệ thống

| Tính năng | Mô tả ngắn |
|---|---|
| Không làm chậm nhận diện | Mọi tính năng phụ chạy khi rảnh hoặc ở mức ưu tiên thấp, tạm dừng khi có công cụ hàng loạt chạy. |
| Không treo giao diện | Mọi tác vụ nặng chạy nền; hộp chọn thư mục không chặn ứng dụng. |
| Thông báo trên Mac | Báo khi có ảnh mới của người được theo dõi. |
| Ký và notarize | Ứng dụng được ký Developer ID và Apple notarize, cài trên Mac khác không bị chặn. |
| Chế độ dòng lệnh | `--headless` để chạy toàn bộ quy trình không giao diện (kiểm thử, đo tốc độ). |
