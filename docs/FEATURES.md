# Tính năng của SuZu Media Utils (v0.8.1)

Ứng dụng macOS cho SuZu Media: nhận diện và nhóm khuôn mặt trong ảnh/video sự kiện, cùng các công cụ xử lý ảnh
hàng loạt. Chạy hoàn toàn trên máy (trừ tra cứu người nổi tiếng qua Amazon, nếu bật).

## Dự án và thư mục

| Tính năng | Mô tả ngắn |
|---|---|
| Tổng quan (Overview) | Màn hình mở đầu: bốn con số (file, người, mặt cần xem, đã giao), quy trình đêm sự kiện 5 bước (Chép thẻ → Nhận diện → Đặt tên → Chọn lọc → Giao) bấm vào là tới màn hình tương ứng, dòng thời gian các phiên (bấm để xem file của phiên), mục "Cần bạn" (người chưa tên, thẻ nhớ vừa cắm, thư mục offline, quy tắc chờ thư mục) và hoạt động trên máy này (đặt tên, gộp, giao file, thư mục). |
| Thanh bên theo quy trình | Overview và Files, rồi Người (People, To Name, Pinned, Unassigned Faces, Search, Auto Rules, Lists, Smart Albums), rồi Công cụ; thư mục thu gọn trong mục Folders. Ô trạng thái dưới cùng cho biết thư viện đang làm gì, tốc độ, thời gian còn lại và đồng bộ nhóm; bấm vào để xem hoạt động. |
| Giao diện sáng / tối | Settings → General: theo hệ thống (kể cả Auto), Sáng hoặc Tối (cũng có ở menu View → Appearance); màu nhấn (cam san hô SuZu hoặc màu của máy); màn hình mở đầu. |
| Dự án (Project) | Mỗi sự kiện là một dự án gồm nhiều thư mục; chuyển dự án ở đầu thanh bên (⇧⌘N để tạo mới). |
| Làm việc theo dự án | Người, tìm kiếm, album, quy tắc tự động, xuất file, gallery và công cụ hàng loạt chỉ hiển thị dữ liệu của dự án đang mở. |
| Tất cả dự án | Xem gộp mọi dự án cùng lúc. |
| Nguồn NAS / ổ ngoài / ổ trong | Thêm thư mục từ NAS (SMB), ổ cứng ngoài hoặc ổ máy; NAS kiểm tra mỗi 5 giây, ổ trong theo dõi tức thì. |
| Theo dõi file mới | File mới chép vào được xử lý ngay khi chép xong; file đang chép dở sẽ được chờ. |
| Thư mục của dự án khác | Settings → Face Grouping → Other projects' folders: thư mục ảnh/video của các dự án không mở được kiểm tra mỗi 30 giây (như dự án đang mở), 5 phút, 15 phút, mỗi giờ, hoặc chỉ khi mở dự án đó. Thư mục dự án đang mở và thư mục Known People luôn được theo dõi; mở dự án là kiểm tra ngay. Nhật ký Activity chỉ ghi "Finished scanning" khi thật sự tìm thấy file mới. |
| Chuyển thư mục giữa dự án | Chuột phải thư mục → Move to Project, không cần quét lại. |
| Chống trùng thư mục | Một thư mục chỉ thuộc một dự án; từ chối thư mục lồng nhau (tránh đếm file hai lần). |
| Theo dõi theo nội dung | Đổi tên, di chuyển trong Finder hoặc chép trùng không làm mất tên người và không xử lý lại. |
| Tìm lại thư mục | Cả thư mục sự kiện bị đổi tên hay di chuyển: chuột phải → Locate Folder… (hoặc thêm lại thư mục), giữ nguyên mọi khuôn mặt và tên. |
| Loại thư mục con | Trong Files, chuột phải thư mục con → Exclude from Library…: file trong đó rời thư viện cùng khuôn mặt và đánh dấu (file trên đĩa giữ nguyên), các lần quét sau bỏ qua; thư mục của team thì áp dụng cho cả team. Thư mục vẫn hiện trong Files, màu xám với dấu trừ và chữ "excluded"; chuột phải → Include in Library (hoặc chuột phải thư mục dự án → Excluded Folders) để lấy lại. |
| Duyệt file (Files) | Cột thư mục bên trái (thư mục dự án, thư mục con của thư mục đang mở, thư mục offline đánh dấu; chuột phải: Finder, Rescan, Locate, Remove), hàng chip lọc (Ảnh/Video, ★3+, Picks, Ẩn ảnh loại, Nhãn, Thư mục con, sắp xếp), chip người trong thư mục; chọn file thì hiện thanh nổi: số file và dung lượng, phím tắt, Write Ratings, Show in Finder, Cull, Export, Open in Edit & Export. Như Finder: xem mọi ảnh/video trong thư mục của dự án theo từng thư mục con, dạng biểu tượng hoặc danh sách (tên, người trong ảnh, ngày chụp, dung lượng, loại); lọc ảnh/video, xem cả thư mục con, tìm theo tên file hoặc tên người, Space để xem nhanh (kèm Edit và Copy Path), nhấp đúp để mở, xuất các file đã chọn. |
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
| Nhận ra dù đổi kiểu | Mỗi người được nhớ bằng nhiều "kiểu mặt" tiêu biểu (chính diện, nghiêng, đội mũ, đeo kính, trang điểm khác…), không chỉ một mặt trung bình: một khuôn mặt chỉ cần giống các ảnh cùng kiểu đã có của người đó là được xếp vào. Nhóm hình thành ở các đợt khác nhau nhưng là cùng một người sẽ tự gộp lại; không bao giờ tự gộp hai người đã đặt tên khác nhau, hay hai nhóm bạn đã tách ("Không phải người này", "Chuyển sang…"). |
| Đặt tên một lần | Người được dùng chung giữa các dự án: đã đặt tên ở sự kiện trước thì sự kiện sau tự nhận ra. |
| Gợi ý tên | Khi gõ tên sẽ gợi ý những người đã đặt tên trước đó; chọn một gợi ý là lưu ngay, không cần Enter. |
| Nhớ mặt người đã đặt tên | Bỏ thư mục, xóa hay sửa file trên đĩa thì vẫn nhớ khuôn mặt của người đã đặt tên: thêm lại đúng ảnh đó, hay gặp lại họ ở sự kiện sau, đều được nhận ra với đúng tên. |
| Một tên, một người | Tên trùng (khác hoa/thường hoặc kiểu mã hóa Unicode) luôn là cùng một người; "New Person…" với tên đã có sẽ gộp vào người đó. |
| "Đây là…" (This Is…) | Gộp một nhóm vào một người đã có tên, ở dự án này hoặc dự án khác. |
| Đặt tên ngay trên lưới | Bấm vào tên để sửa, Enter để lưu và chuyển sang nhóm chưa có tên tiếp theo. |
| Gộp nhóm | Chọn nhiều nhóm (⌘-click) rồi gộp làm một. |
| Sửa nhầm lẫn | "Không phải người này" (không tự gán lại), "Chuyển sang…" người khác hoặc người mới. Mỗi lần sửa, app học: các mặt giống mặt vừa bỏ hơn giống người đó cũng rời đi (theo sang người mới nếu khớp), ảnh mới của người giống sẽ không gán nhầm lại, hai người đã tách không bị gộp lại. |
| Khuôn mặt chưa gán | Danh sách khuôn mặt rõ nét chưa thuộc nhóm nào để đặt tên thủ công. Phía trên là "Seen twice": các cặp mặt giống nhau mới gặp hai lần (nhóm cần ba), một bấm là thành người. Chuột phải lên khuôn mặt (hoặc ⌘-click chọn nhiều): "New Person…" để đặt tên người mới, "Move to" để chuyển vào người đã có tên. |
| Thư mục người quen (Known People) | Thư mục `<Tên>/<ảnh>` giúp tự đặt tên các nhóm khớp, không cần mạng. |
| Gợi ý tên người nổi tiếng | Tra cứu nhóm chưa tên qua Amazon Rekognition (tùy chọn, chỉ gửi ảnh cắt khuôn mặt). |
| Cũng có trong… | Trang người hiển thị các dự án khác mà người đó xuất hiện. |

## Ảnh đẹp nhất và xem ảnh

| Tính năng | Mô tả ngắn |
|---|---|
| Chấm điểm ảnh | Mỗi khuôn mặt được chấm theo chất lượng, độ nét, mắt mở, góc mặt, nụ cười, kích thước. |
| Ảnh đại diện | Tự chọn ảnh đẹp nhất (nét, mở mắt, nhìn thẳng) hoặc chọn thủ công bất kỳ ảnh nào. |
| Đặt tên liền tay | Ô tên luôn có sẵn dưới mỗi khuôn mặt ("Add name" khi chưa có tên): bấm vào, gõ, ⏎ — con trỏ nhảy sang người chưa tên kế tiếp; ⇥ bỏ qua một người; gõ tên thì gợi ý người đã đặt tên ở mọi dự án. Nút Start Naming trên băng nhắc bắt đầu từ người chưa tên đầu tiên. Chọn nhiều ô (⌘-bấm, ⇧-bấm) hiện thanh nổi: Gộp thành một, Đây là…, Ghim, Thêm vào danh sách, Mở. |
| Ghim người (Pinned) | Sự kiện có cả nghìn mặt; ghim những người quan trọng (chuột phải → Pin, thanh nổi, hoặc ★ trên trang người) thì họ luôn đứng đầu mọi lưới, có sao vàng trên ảnh; mục Pinned ở thanh bên chỉ xem họ. |
| Danh sách người (Lists) | Lập danh sách: Cast, Producers, Sponsors, Guests, VIP, VVIP (gợi ý sẵn) hoặc tên tuỳ ý. Thêm người bằng chuột phải → Add to List, thanh nổi khi chọn nhiều, hoặc "+ Add to list" trên trang người; mỗi danh sách là một mục ở thanh bên (số người trong dự án), bấm vào để chỉ xem họ. Gộp hai người thì người còn lại giữ mọi danh sách và ghim. Danh sách và ghim là của máy này, áp dụng cho người đó ở mọi dự án (như tên). |
| Trang người | Ảnh đại diện, tên (bấm để đổi), số ảnh/video và khoảng giờ chụp, "Thường chụp cùng" (bấm mặt để chỉ xem ảnh chụp chung); tab Ảnh / Video / Khuôn mặt; sắp xếp Đẹp nhất, Theo giờ, Theo tên; Best 10/20/50/100 và Ẩn ảnh trùng là chip; mỗi ảnh ghi điểm ảnh đẹp, số ảnh trùng, giờ và phiên. Chọn ảnh → Open in Edit & Export. |
| Ẩn ảnh chụp liên tiếp | Chỉ giữ ảnh đẹp nhất trong mỗi loạt ảnh gần giống nhau (burst). |
| Lọc "Cùng với…" | Chỉ hiện ảnh có người này chụp chung với người khác. |
| Phát video | Ô video có nút phát và mốc thời gian người đó xuất hiện. |
| Space để xem nhanh | Như Quick Look của Finder: Space mở ô dưới con trỏ chuột (không có thì ô bấm gần nhất, rồi ô đang chọn), Space lần nữa để đóng. Khuôn mặt (People, tab Khuôn mặt, Khuôn mặt chưa gán) phóng to trong popover, cắt sắc nét từ ảnh gốc hoặc khung hình video, kèm tên file; ← → xem mặt trước/sau, Esc đóng. Ảnh và video (tab Ảnh/Video, Search, Files, danh sách file của Công cụ) cũng mở trong popover: ảnh lớn hoặc video phát từ lúc người đó xuất hiện, nút Edit (mở ảnh trong Edit & Export) và Copy Path. |

## Phiên trong sự kiện (Sessions)

| Tính năng | Mô tả ngắn |
|---|---|
| Tự chia phiên | Tự tách sự kiện thành các phiên (khai mạc, trận đấu, trao giải…) ở chỗ ngừng chụp 30 phút (chỉnh được 10–120 phút). |
| Lọc người theo phiên | Bấm một phiên trên trang People để chỉ xem ai có mặt và số ảnh trong phiên đó. |
| Đặt tên phiên | Chuột phải → Rename Session (vd. "Trao giải"); tên giữ nguyên khi có thêm file. |
| Phiên áp dụng mọi nơi | Thanh phiên hiện trên People, trang người, khuôn mặt chưa gán, Files, Search và Edit & Export (kể cả khi chỉ có một phiên). Bấm một phiên để chỉ xem hoặc xuất ảnh của phiên đó; Copy/Move cũng theo phiên. Trong Edit & Export, nguồn Files & Folders đọc giờ chụp của file để lọc theo phiên (dòng "n of m photos in …"). |
| Chọn nhiều | Trong mọi lưới: ⌘-click thêm từng mục, ⇧-click chọn một dải từ mục đang chọn tới mục bấm. |

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
| Quy tắc bỏ ảnh trùng, ảnh mờ | Trong điều kiện của quy tắc (và tìm kiếm, smart album) có "Skip similar shots" (chỉ ảnh đẹp nhất mỗi loạt; quy tắc chờ đến khi biết loạt của ảnh mới) và "Skip blurry shots" (bỏ ảnh mặt chính mất nét). |

## Nhóm làm việc (Team) — nhiều máy, nhiều sự kiện

| Tính năng | Mô tả ngắn |
|---|---|
| Một nhóm, nhiều dự án | Nhóm là một thư mục mọi máy đều mở được (share NAS, Dropbox, iCloud Drive) và chứa mọi dự án bạn chia sẻ với nhóm. Thanh bên hiện Nhóm ở trên, Dự án ở dưới; menu dự án gom theo nhóm (và "Chỉ trên máy này"). |
| Chia sẻ dự án | File → Share Project with Team…: tạo nhóm mới trong một thư mục, hoặc thêm dự án vào nhóm đang có. Không cần tài khoản hay máy chủ. Stop Sharing để rút dự án khỏi nhóm trên máy này. |
| Tham gia nhóm | Trên máy khác: File → Join a Team…, chọn đúng thư mục đó một lần; các dự án của nhóm tự xuất hiện, rồi thêm thư mục ảnh của mình vào dự án đang chụp. |
| Nhận diện chung | Đặt tên một người trên máy nào thì mọi máy trong nhóm đều nhận ra người đó (kể cả máy của người khác) trong vài giây. Mỗi máy còn chia sẻ vài "kiểu mặt" tiêu biểu của từng người, nên mặt nghiêng thấy ở máy này khớp với mặt nghiêng ở máy kia. |
| Một máy nhận diện cho cả nhóm | Trong menu Team: "This Mac processes faces for the team". Máy mạnh nhận diện; các máy chép thẻ và chỉnh ảnh không tốn CPU/GPU, chỉ đọc kết quả (khuôn mặt, người, nhóm, ảnh cắt) từ thư mục chung cho đúng những file mình thấy. Sửa trên máy nào ("Không phải người này", "Chuyển sang…", đặt tên, gộp, chọn ảnh đại diện) cũng về máy nhận diện và lan ra mọi máy. Thanh trạng thái báo "Waiting for <máy>: N files". "Every Mac processes its own files" trở lại như cũ. Lai (hybrid): máy chép thẻ vẫn tự nhận diện các file mình chép, đọc từ thẻ ngay khi từng file hạ xuống, rồi gửi khuôn mặt (chưa gộp) lên thư mục nhóm; máy nhận diện lấy bản đó cho file đang chờ thay vì đọc lại từ NAS, gộp người, rồi gửi lại file kèm người; mọi máy (kể cả máy chép) nhận bản của máy nhận diện làm chuẩn cho đúng những khuôn mặt mình tìm được. Khi có máy chép đang gửi, máy nhận diện chờ file mới 30 giây cho bản ghi tới trước khi tự đọc; không thì đọc ngay như cũ. |
| Dữ liệu được chia sẻ | Dự án (tên), tên người, gộp người, tên phiên và quy tắc tự động. Ảnh, khuôn mặt và ảnh cắt vẫn ở máy nào xử lý máy đó. |
| Làm việc cùng lúc | Mỗi máy ghi vào nhật ký riêng của mình trong thư mục và đọc của máy khác, nên nhiều máy chạy cùng lúc không đụng nhau; máy mất mạng sẽ tự bắt kịp khi có lại. |
| Thay đổi mới nhất thắng | Hai máy cùng sửa tên: tên sửa sau thắng. Cùng một tên đặt trên hai máy thì gộp thành một người. |
| Trạng thái nhóm | Thẻ nhóm hiện tên nhóm, số máy, lần đồng bộ gần nhất và danh sách dự án trong nhóm; thư mục không truy cập được thì báo và tự tiếp tục khi có lại. Sync Now, Rename Team, mở thư mục nhóm, Leave Team (giữ dự án và tên người). |
| Đổi địa chỉ thư mục nhóm | NAS đổi địa chỉ hoặc share gắn tên khác: Locate Team Sync Folder… trỏ nhóm sang chỗ mới của cùng thư mục, không mất gì. |
| Ba loại thư mục trong nhóm | Team Folders: thư mục nguồn cả nhóm cùng làm (thư mục thẻ trên NAS), thêm ở một máy là hiện trên mọi máy của nhóm. Edited Folders: thư mục kết quả của máy chỉnh sửa / lọc / chọn ảnh, cũng lan ra mọi máy. Folders on This Mac: chỉ ở máy đó, như trước. Thanh bên và Files chia ba nhóm; chuột phải thư mục → In the Team để đổi loại. Mỗi máy tìm thư mục chung theo khoảng cách tới thư mục nhóm nên share gắn tên khác vẫn đúng; rút thư mục khỏi nhóm thì máy chỉ có nó qua nhóm sẽ bỏ, máy tự thêm giữ lại làm của mình. |
| Người quen đi theo mọi sự kiện | Mọi người có tên trên một máy (thư mục Known People chuẩn bị trước sự kiện, người từ các sự kiện trước) đều được chia sẻ với nhóm, nên máy mới tham gia biết hết. |
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
| Xem ảnh như trình chỉnh sửa | ⌘+ / ⌘− phóng to, thu nhỏ; ⌘0 vừa khung; ⌘1 100% (1 pixel ảnh = 1 pixel màn hình); giữ Z + bấm để phóng to một nấc ngay chỗ bấm, ⌥Z + bấm để thu nhỏ (như công cụ Zoom của Photoshop, tiện khi tô mask hay chấm mụn); ⌥-cuộn hoặc chụm ngón để phóng quanh con trỏ; cuộn hoặc giữ Space + kéo để di chuyển; bấm đúp đổi giữa 100% và vừa khung. Ảnh xem trước luôn dựng ở độ phân giải màn hình nên watermark sắc nét ở mọi mức phóng. |
| Công cụ cắt (C) | Phím C (hoặc nút Crop): khung cắt có 8 tay nắm để kéo (giữ tỉ lệ của khung xuất, khung gốc, preset, hoặc Free tự do), kéo bên trong để dời, kéo bên ngoài để xoay ảnh, nút Straighten rồi kéo một đường dọc theo thứ cần nằm ngang (sàn, đường chân trời, cột); ⏎ áp dụng, Esc huỷ, phím mũi tên dịch khung. Ghi nhớ theo từng ảnh, dùng cho mọi màn hình xuất; "Reset crop" quay lại tự động. |
| Chỉnh vị trí cắt bằng tay | Ở chế độ vừa khung, kéo ảnh trong khung xem trước để đặt vị trí cắt (ảnh trượt dưới khung). |
| Phóng to vùng cắt (cắt bớt rìa) | Nút "Zoom": thu nhỏ vùng cắt tới 4 lần (giữ phần giữa 25% mỗi cạnh) để bỏ phần thừa ở rìa ảnh sự kiện, kể cả khi ảnh giữ nguyên khung gốc; khung cắt hiện ngay trên ảnh khi kéo thanh trượt. Thanh trượt Level cũng xoay ảnh ngay khi kéo. |
| Ánh sáng, màu, chi tiết | Light: Exposure, Contrast, Highlights, Shadows. Colour: Temperature, Tint, Vibrance, Saturation, Black & white. Detail: Sharpen, Clarity, Vignette. Orientation: xoay 90°, lật ngang/dọc. Menu Looks có sẵn vài phong cách (Natural, Vivid, Soft, Warm, Cool, Black & White, Stage) để bắt đầu; bấm đúp tên thanh trượt để về 0. Nhiều ảnh: "All photos" áp dụng cho cả loạt hoặc "This photo only" chỉ ảnh đang xem. |
| Đường cong tông (Tone curve) | Mục Tone Curve: 5 điểm (0, ¼, ½, ¾, 1) kéo lên/xuống để sáng/tối từng vùng tông (bóng bên trái, vùng sáng bên phải); bấm đúp điểm để trả về đường thẳng. |
| HSL theo từng màu | Mục HSL: Hue / Saturation / Luminance cho 8 màu (đỏ, cam, vàng, lục, xanh ngọc, lam, tím, hồng), như bảng HSL của Lightroom; màu xám không bị ảnh hưởng. |
| Lưu Look riêng | Menu Looks: "Save Current Look…" lưu toàn bộ thanh trượt (ánh sáng, màu, chi tiết, đường cong, HSL) thành look có tên, hiện trong mọi màn hình chỉnh sửa; xoá được. "Copy Look" / "Paste Look" chép look từ ảnh này sang ảnh khác. |
| Hoàn tác (Undo) | ⌘Z / ⇧⌘Z (menu Edit) trong Edit & Export hoàn tác mọi thay đổi: thanh trượt, look, khung cắt, xoay, watermark, kích thước; một lần kéo thanh trượt là một bước. |
| Khung riêng cho từng ảnh | Menu "Crop" góc trên bên trái ảnh xem trước: chọn khung riêng cho ảnh đó (hoặc "Same as the others"). Ảnh đã chỉnh có biểu tượng khung cắt trên ảnh nhỏ. |
| Không xuất trùng | Ghi nhớ ảnh nào đã xuất ra file nào (dấu ✓ xanh trên ảnh nhỏ, ngày xuất ở thanh thông tin). Khi xuất lại vào cùng thư mục, hỏi từng ảnh: Skip / Overwrite, có ô "Apply to all". Không bao giờ ghi đè ảnh gốc; hai ảnh khác nhau trùng tên vẫn được thêm " (2)". |
| Watermark logo hoặc chữ | Logo PNG hoặc dòng chữ (vd. "© SuZu Media") có bóng đổ; chỉnh vị trí, kích thước, độ mờ, khoảng cách lề. Chữ chọn được phông và kiểu chữ (Regular, Bold…) trong các phông có trên máy. |
| Chữ kèm logo hoặc banner | Bật "Text as well" để thêm một dòng chữ cùng lúc với logo hoặc banner, với chữ, phông, màu, vị trí, kích thước, độ mờ và lề riêng, hoặc lấy từ một mẫu chữ (Preset); tắt đi vẫn giữ nguyên để bật lại. Chữ nằm cùng cạnh với banner thì lề tính từ mép banner, không từ mép ảnh. Lưu được trong mẫu watermark. |
| Watermark dạng banner | Thanh ngang trải hết chiều rộng ảnh (trên, giữa hoặc dưới); một ảnh banner cho ảnh ngang, một cho ảnh dọc, tự chọn theo hướng ảnh. Đặt chiều cao banner (mặc định 112 px trên ảnh cạnh dài 2048 px, tính theo cạnh dài) nên ảnh ngang hay dọc, khung nào cũng cao như nhau; banner được căn giữa, hai bên dư được cắt bỏ (banner hẹp hơn ảnh thì được kéo giãn ngang, chiều cao không đổi). Làm banner rộng hơn ảnh một chút và để chữ, logo ở vùng an toàn giữa banner. |
| Mẫu watermark (preset) | Lưu nhiều mẫu trong Settings → Watermarks; mỗi màn hình chọn và chỉnh mẫu riêng, lưu lại hoặc lưu thành mẫu mới. |
| Căn vị trí watermark | Lưới 3×3 hoặc bấm thẳng lên ảnh xem trước để đặt watermark logo/chữ (banner giữ vị trí trên/giữa/dưới đã chọn, bấm lên ảnh không đổi). |
| Nhớ cài đặt theo màn hình | Mỗi màn hình (Edit & Export, Copy/Move, quy tắc tự động, gallery, ảnh từ video) nhớ cài đặt chỉnh sửa riêng. |
| Xem trước lớn | Ảnh xem trước lớn, so sánh trước/sau, hiện kích thước đầu ra, dải ảnh thu nhỏ để chọn ảnh khác. |
| Thay đổi kích thước | Cạnh dài 1080–3000 px hoặc kích thước gốc. Khi cắt khung, mặc định cạnh dài 2048 px (Facebook hiển thị tới 2048 px mà không thu nhỏ); vẫn chọn được cỡ riêng của từng nền tảng (vd. 1350 px cho Instagram 4:5). Giữ khung gốc thì giữ kích thước gốc. |
| Xuất JPEG hoặc PNG | JPEG chỉnh được chất lượng; PNG không nén mất dữ liệu, giữ không gian màu gốc, 16-bit nếu ảnh gốc sâu hơn 8-bit. |

## Công cụ hàng loạt

| Tính năng | Mô tả ngắn |
|---|---|
| Mở để chỉnh & xuất | Chuột phải → Open trên ảnh ở mọi màn hình (People, khuôn mặt, khuôn mặt chưa gán, tìm kiếm, smart album) mở cửa sổ "Edit & Export" với đúng ảnh đó; ⌘-click chọn nhiều ảnh rồi Open để mở tất cả. Video mở bằng ứng dụng mặc định. |
| Retouch: da và vùng người | Trong Edit & Export: làm mịn da (giữ lỗ chân lông, mắt, lông mày sắc nét), làm sáng da, làm trắng da (bớt vàng, hồng hơn, sáng hơn), có thể áp cho cả da thân (tay, chân, vai). Mask tự nhận trên từng ảnh: da mặt, da thân, môi, quần áo (mô hình Sapiens của Meta, tải một lần bằng nút Download Model trong mục Retouch và giữ qua các bản cập nhật; chưa tải thì dùng Apple Vision, mask thô hơn); mỗi mask có thanh chỉnh riêng (phơi sáng, tương phản, bão hoà, nhiệt độ màu, tint, đổi màu), độ mềm viền và nới/thu mask; "Show mask" tô đỏ mask đang chọn trên ảnh xem trước. Làm mịn / sáng / trắng da dùng chung mask da mặt và da thân của mục Masks (da thân khi bật "Body skin too"): nới/thu, độ mềm viền hay tô lại mask da mặt, da thân ở bất cứ đâu đều đổi cả hai; tô trong mục làm da thì chọn tô lên da mặt hay da thân. Phóng to ảnh xem trước dùng lại mask đã tìm (trước đây phải tìm lại mất gần một phút, nên tô mask hay chữa da khi phóng to như không có tác dụng). |
| Healing brush (cọ chữa da) | Trong mục Retouch, như Spot Healing Brush của Photoshop: bật "Healing brush" rồi tô lên mụn, nốt ruồi, tàn nhang, nếp nhăn trên ảnh xem trước; app tự tìm vùng da sạch gần đó (khớp vân da và màu ở viền, tránh vùng có đốm), chép vân da sang và hoà ánh sáng, màu với da xung quanh nên không thấy vết nối. Mọi chỗ cọ phủ đều được chữa hết (viền mềm làm nhoà ra ngoài cọ chứ không để lại một phần nốt ruồi ở mép), và phần đốm lấn ra ngoài cọ không bị kéo màu tối vào trong. Nét dài (nếp nhăn) được chữa từng đoạn, đoạn sau không làm tối đầu đoạn trước. Thanh "Amount" chỉnh mức chữa hiện trên ảnh (0–100%, như độ mờ lớp chữa trong Photoshop), chỉnh lúc nào cũng được. ⌥-bấm để tự chọn chỗ lấy da (như Healing Brush: các nét sau giữ cùng khoảng cách), "Auto" để quay lại tự tìm. Cỡ cọ tính bằng pixel của ảnh gốc (1–2500 px, thanh trượt chỉnh mịn từng pixel ở cỡ nhỏ và nhanh dần ở cỡ lớn, như Photoshop; cọ tô mask cũng vậy), độ mềm viền, [ ] đổi cỡ theo nấc của Photoshop, đếm số nét, hoàn tác từng nét (⌘Z hoặc nút ↩) và Clear; không cần Find Masks. Nét chữa thuộc riêng từng ảnh, đi theo ảnh khi xoay, lật, cân thẳng và khi xuất; ảnh xem trước ở mọi mức phóng và ảnh xuất chọn cùng một chỗ lấy da. |
| Whites / Blacks | Hai thanh chỉnh mới trong Light: đẩy vùng sáng nhất tới trắng (hoặc giữ lại), vùng tối nhất tới đen (hoặc nâng lên), gần như không đụng vùng giữa. |
| Edit & Export | Cân màu, cắt khung, watermark, đổi kích thước cho file/thư mục hoặc ảnh của những người đã chọn. Không bao giờ ghi đè: tên đã có thì thêm " (2)". |
| Chọn ảnh để xuất | Tích/bỏ tích từng ảnh trên dải ảnh hoặc lưới (⇧-click chọn dải, Chọn tất cả / Bỏ chọn tất cả). |
| Điều hướng bằng bàn phím | Phím ← → (và ↑ ↓ trên lưới, theo hàng) chuyển ảnh trong dải ảnh/lưới; Home/End về đầu/cuối; Space tích hoặc bỏ tích ảnh đang xem; Return mở ảnh trên lưới ra xem lớn. Bấm vào ảnh xem trước hoặc dải ảnh để lấy tiêu điểm bàn phím. |
| File RAW | Nhận file RAW của máy ảnh (Canon, Nikon, Sony, Fujifilm, Olympus, Panasonic, Pentax, Leica, Hasselblad, Phase One, Sigma, DNG…) như ảnh thường: nhận diện, tìm kiếm, xuất, chỉnh (ảnh RAW đã chỉnh xuất ra JPEG). Dùng ảnh xem trước trong file nên không chậm hơn. Chụp RAW+JPEG: file RAW đi kèm JPEG cùng tên, hiện người của JPEG, không xử lý hay xuất riêng; riêng Edit & Export dùng file RAW của cặp (nhiều chi tiết nhất để chỉnh). |
| Bỏ ảnh trùng, ảnh mờ | Tuỳ chọn "Skip similar shots" và "Skip blurry shots" trong Edit & Export (file/thư mục): kiểm tra ảnh trước khi xuất rồi bỏ tích ảnh chụp liên tiếp giống nhau (giữ ảnh đẹp nhất) và ảnh mờ (mặt chính mất nét/rung; ảnh không có mặt thì xét cả khung). Rê chuột lên ảnh để xem lý do; tích lại nếu muốn giữ. Copy/Move cũng có "Skip blurry shots". |
| Nguồn là người | Edit & Export, Batch Rename, Video Tools nhận đầu vào là người: N ảnh đẹp nhất, bỏ ảnh trùng, mỗi người một thư mục. |
| Batch Rename | Đổi tên theo mẫu `{event} {date} {time} {person} {people} {folder} {seq}` có xem trước; thư viện tự cập nhật đường dẫn. |
| Chép từ thẻ nhớ (Copy from Cards) | Mỗi thẻ cắm vào là một thẻ bài: tên, máy ảnh, dung lượng; có gì mới viết thành một câu ("312 ảnh mới · 14 video mới · 9,8 GB"), nhãn trạng thái (Mới từ 14:05 · Đang chép · Đã chép hết), file sẽ về đâu, một nút Copy New Files; đích và tùy chọn ở cột phải; Copy New Files from All chép mọi thẻ có file mới cùng lúc. Thẻ của các nhiếp ảnh gia đưa đi đưa lại nhiều lần trong sự kiện mà không xóa: ứng dụng nhận ra từng thẻ theo UUID của ổ (không cần đổi tên thẻ), ghi sổ mọi file đã chép từ thẻ đó, lần sau chỉ chép file mới chụp — dù bản chép trước đã bị chuyển đi, lọc hay chỉnh sửa. File đổi tên trên thẻ hoặc đã có trong thư viện (chép tay) cũng nhận ra theo nội dung, không chép hai lần. Mỗi thẻ một thư mục ở đích, mỗi lần đưa thẻ một thư mục con theo giờ (tùy chọn); đặt tên thẻ ("Nam R5 thẻ 1"), hiện máy ảnh và số serial thân máy từ EXIF; chép có kiểm tra SHA-256, giữ nguyên giờ file; kiểm tra chỗ trống ở đích; tự thêm thư mục thẻ vào dự án đang mở để nhận diện ngay. Chuột phải thẻ đã gặp → Forget để chép lại từ đầu. Trong nhóm (Team), sổ chép đi theo thư mục chung: thẻ chép ở máy này thì máy khác cũng biết, lần sau đưa thẻ cho máy nào rảnh cũng được, qua khe cắm hay đầu đọc/adapter nào cũng vậy. Rút thẻ giữa chừng: dừng ngay, file đã chép xong được giữ và ghi sổ, không để lại file dở; cắm lại thì chép tiếp phần còn lại vào đúng thư mục đó. Đếm riêng ảnh mới và video mới; có thể chép video sang một thư mục đích khác (ổ của người dựng phim), ảnh một nơi, video một nơi, mỗi nơi vẫn có thư mục riêng của thẻ. Cắm nhiều thẻ cùng lúc: mỗi thẻ có thể chép sang một đích riêng (thẻ này vào máy, thẻ kia vào SSD rời, thẻ nữa lên NAS — thẻ nhớ đích đó cho lần đưa sau), các thẻ chép song song, mỗi ổ chạy hết tốc độ của mình. Chép thẻ, nhận diện và chép/chuyển thư mục chạy cùng lúc không cản nhau: thư mục thẻ vào dự án trước khi file đầu tiên hạ xuống, mỗi file vừa hạ xuống là được nhận ngay, xếp trước mọi việc đang chờ, khuôn mặt đọc từ thẻ (USB, cục bộ) khi thẻ còn cắm thay vì đọc lại từ NAS vài phút sau khi quét tới (lúc đó thẻ đã rút để cắm thẻ kế), nên mạng chỉ chở mỗi ảnh một lần và chép xong là đã biết mặt; rút thẻ sớm thì phần còn lại đọc từ NAS; quét thư mục thấy file đã có thì bỏ qua, RAW đi kèm JPEG để quét ghép đôi như cũ; khi đang chép thẻ hay xuất ảnh, nhận diện giảm còn nửa số luồng để chép được ưu tiên ổ đĩa và mạng, xong lại chạy đủ; Copy/Move sang thư mục người chạy nhiều file song song (tên trùng vẫn tách riêng); thư viện ghi không chờ đĩa (WAL, synchronous=NORMAL) và cho nhiều luồng đọc hơn nên các việc không xếp hàng sau nhau. |
| Copy Verifier | So sánh thư mục gốc và bản sao (mặc định so cả nội dung bằng SHA-256), tìm file thiếu hoặc lỗi và sửa lại; bản sửa được kiểm tra trước khi thay bản hỏng. |
| Video Tools | Tạo bản proxy 720p và contact sheet (lưới khung hình có mốc thời gian) cho nhiều video. |

## Hiệu năng và hệ thống

| Tính năng | Mô tả ngắn |
|---|---|
| Ảnh thu nhỏ tức thì | Mỗi file có ảnh thu nhỏ làm sẵn (lúc nhận diện, hoặc lúc rảnh) lưu trong thư viện, nên mở thư mục trên NAS hiện ngay như Finder; máy không nhận diện nhận ảnh thu nhỏ qua thư mục nhóm. Ẩn ảnh trùng (burst) giữ file RAW trước JPEG/PNG. Chuột phải: Copy File Path. |
| Không làm chậm nhận diện | Mọi tính năng phụ chạy khi rảnh hoặc ở mức ưu tiên thấp, tạm dừng khi có công cụ hàng loạt chạy. |
| Không treo giao diện | Mọi tác vụ nặng chạy nền; hộp chọn thư mục không chặn ứng dụng. |
| Thông báo trên Mac | Báo khi có ảnh mới của người được theo dõi. |
| Ký và notarize | Ứng dụng được ký Developer ID và Apple notarize, cài trên Mac khác không bị chặn. |
| Chế độ dòng lệnh | `--headless` để chạy toàn bộ quy trình không giao diện (kiểm thử, đo tốc độ). |
