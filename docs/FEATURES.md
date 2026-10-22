# Tính năng của SuZu Media Utils (v0.5.1)

Ứng dụng macOS cho SuZu Media: nhận diện và nhóm khuôn mặt trong ảnh/video sự kiện, cùng các công cụ xử lý ảnh
hàng loạt. Chạy hoàn toàn trên máy (trừ tra cứu người nổi tiếng qua Amazon, nếu bật).

## Dự án và thư mục

| Tính năng | Mô tả ngắn |
|---|---|
| Dự án (Project) | Mỗi sự kiện là một dự án gồm nhiều thư mục; chuyển dự án ở đầu thanh bên (⇧⌘N để tạo mới). |
| Làm việc theo dự án | Người, tìm kiếm, album, quy tắc gửi, xuất file, gallery và công cụ hàng loạt chỉ hiển thị dữ liệu của dự án đang mở. |
| Tất cả dự án | Xem gộp mọi dự án cùng lúc. |
| Nguồn NAS / ổ ngoài / ổ trong | Thêm thư mục từ NAS (SMB), ổ cứng ngoài hoặc ổ máy; NAS kiểm tra mỗi 5 giây, ổ trong theo dõi tức thì. |
| Theo dõi file mới | File mới chép vào được xử lý ngay khi chép xong; file đang chép dở sẽ được chờ. |
| Chuyển thư mục giữa dự án | Chuột phải thư mục → Move to Project, không cần quét lại. |
| Chống trùng thư mục | Một thư mục chỉ thuộc một dự án; từ chối thư mục lồng nhau (tránh đếm file hai lần). |
| Theo dõi theo nội dung | Đổi tên, di chuyển trong Finder hoặc chép trùng không làm mất tên người và không xử lý lại. |
| Tìm lại thư mục | Cả thư mục sự kiện bị đổi tên hay di chuyển: chuột phải → Locate Folder… (hoặc thêm lại thư mục), giữ nguyên mọi khuôn mặt và tên. |

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
| Khuôn mặt chưa gán | Danh sách khuôn mặt rõ nét chưa thuộc nhóm nào để đặt tên thủ công. |
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
| Quy tắc gửi tự động | Ảnh mới của một người (hoặc mọi người có tên) tự chép vào thư mục (vd. Google Drive, Dropbox), có thể kèm chỉnh sửa, và báo trên Mac. Thư mục đích chưa gắn hoặc lỗi chép thì tự thử lại sau. |
| Khoảnh khắc video | Mỗi người: cắt từng đoạn xuất hiện (không nén lại), dựng video highlight, hoặc xuất khung hình đẹp nhất. |
| Web gallery tĩnh | Xuất thư mục gallery có index.html, mở bằng trình duyệt hoặc chia sẻ qua Drive/NAS. |
| Gallery trong mạng nội bộ | Chia sẻ gallery qua link bí mật trong mạng LAN để xem, phát video, tải ảnh gốc và đặt tên từ iPad, điện thoại. Chỉ truy cập được ảnh của dự án đang mở. |

## Chỉnh sửa ảnh

| Tính năng | Mô tả ngắn |
|---|---|
| Tự động cân màu | Tự chỉnh phơi sáng, tương phản, vùng sáng/tối, màu da; chỉnh được độ mạnh. Tự bật khi cắt khung hoặc đóng watermark. |
| Cắt khung mạng xã hội | 1:1, 4:5, 9:16, 16:9, 1.91:1; giữ khuôn mặt trong khung (cả nhóm nếu vừa). |
| Watermark logo hoặc chữ | Logo PNG hoặc dòng chữ (vd. "© SuZu Media") có bóng đổ; chỉnh vị trí, kích thước, độ mờ, khoảng cách lề. |
| Mẫu watermark (preset) | Lưu nhiều mẫu trong Settings → Watermarks; mỗi màn hình chọn và chỉnh mẫu riêng, lưu lại hoặc lưu thành mẫu mới. |
| Căn vị trí watermark | Lưới 3×3 hoặc bấm thẳng lên ảnh xem trước để đặt watermark. |
| Nhớ cài đặt theo màn hình | Mỗi màn hình (Batch Export, Copy/Move, quy tắc gửi, gallery, ảnh từ video) nhớ cài đặt chỉnh sửa riêng. |
| Xem trước lớn | Ảnh xem trước lớn, so sánh trước/sau, hiện kích thước đầu ra, dải ảnh thu nhỏ để chọn ảnh khác. |
| Thay đổi kích thước | Cạnh dài 1080–3000 px hoặc kích thước gốc; cỡ khuyến nghị theo từng nền tảng. |
| Xuất JPEG hoặc PNG | JPEG chỉnh được chất lượng; PNG không nén mất dữ liệu, giữ không gian màu gốc, 16-bit nếu ảnh gốc sâu hơn 8-bit. |

## Công cụ hàng loạt

| Tính năng | Mô tả ngắn |
|---|---|
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
