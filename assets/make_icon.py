"""Dessine l'icône de hdCLEANER (1024 px, couleurs Socle) puis produit icon.icns avec iconutil.
Un plateau de disque dur et son bras de lecture, avec un secteur rendu à la couleur du logo : l'espace libéré."""
import os, subprocess, sys, tempfile
from PyQt6.QtCore import QPointF, QRectF, Qt
from PyQt6.QtGui import QColor, QGuiApplication, QImage, QLinearGradient, QPainter, QPen

here = os.path.dirname(os.path.abspath(__file__))
LOGO = QColor("#a78bfa")  # couleur du logo : le « hd » du nom dans l'appli

app = QGuiApplication(sys.argv)
img = QImage(1024, 1024, QImage.Format.Format_ARGB32)
img.fill(Qt.GlobalColor.transparent)
p = QPainter(img)
p.setRenderHint(QPainter.RenderHint.Antialiasing)
p.setPen(Qt.PenStyle.NoPen)

tile = QRectF(100, 100, 824, 824)
g = QLinearGradient(tile.topLeft(), tile.bottomLeft())
g.setColorAt(0, QColor("#2c2f34"))
g.setColorAt(1, QColor("#1b1d21"))
p.setBrush(g)
p.drawRoundedRect(tile, 180, 180)

# plateau et secteur libéré
disc = QRectF(212, 212, 600, 600)
p.setBrush(QColor("#3a3d43"))
p.drawEllipse(disc)
p.setBrush(LOGO)
p.drawPie(disc, 90 * 16, -115 * 16)
p.setPen(QPen(QColor("#2c2f34"), 8)); p.setBrush(Qt.BrushStyle.NoBrush)
for inset in (70, 140):
    p.drawEllipse(disc.adjusted(inset, inset, -inset, -inset))
p.setPen(Qt.PenStyle.NoPen)
p.setBrush(QColor("#1b1d21"))
p.drawEllipse(QPointF(512, 512), 92, 92)
p.setBrush(QColor("#f2f2f2"))
p.drawEllipse(QPointF(512, 512), 42, 42)

# bras de lecture
pen = QPen(QColor("#f2f2f2"), 42); pen.setCapStyle(Qt.PenCapStyle.RoundCap)
p.setPen(pen)
p.drawLine(QPointF(800, 768), QPointF(610, 650))
p.setPen(Qt.PenStyle.NoPen)
p.setBrush(QColor("#f2f2f2"))
p.drawEllipse(QPointF(800, 768), 50, 50)
p.end()

img.save(os.path.join(here, "icon.png"))
with tempfile.TemporaryDirectory() as tmp:
    iconset = os.path.join(tmp, "icon.iconset"); os.mkdir(iconset)
    for s in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            n = f"icon_{s}x{s}{'@2x' if scale == 2 else ''}.png"
            img.scaled(s * scale, s * scale, Qt.AspectRatioMode.KeepAspectRatio,
                       Qt.TransformationMode.SmoothTransformation).save(os.path.join(iconset, n))
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(here, "icon.icns")], check=True)
print("icon.icns OK")
