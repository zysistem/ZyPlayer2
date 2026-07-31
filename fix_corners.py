import sys
from PIL import Image

src_path = "/Users/zulfuyildiz/Desktop/ZyPlayer/icon_1024.png"
out_path = "/Users/zulfuyildiz/Desktop/ZyPlayer/icon_clean.png"

img = Image.open(src_path).convert("RGBA")
datas = img.getdata()

new_data = []
for item in datas:
    # If the pixel is white or near white (r, g, b > 250)
    if item[0] > 250 and item[1] > 250 and item[2] > 250:
        new_data.append((0, 0, 0, 0)) # Make pixel 100% transparent
    else:
        new_data.append(item)

img.putdata(new_data)
img.save(out_path, "PNG")
print("Corners cleaned successfully!")
