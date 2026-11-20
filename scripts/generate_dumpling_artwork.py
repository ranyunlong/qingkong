#!/usr/bin/env python3
"""Convert the approved SVG preview layers to native SwiftUI paths (no runtime SVG dependency)."""
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
preview = (ROOT / 'Design/Previews/dumpling-watch.html').read_text()
drawings = json.loads(re.search(r'const drawings\s*=\s*(\[.*?\]);\nconst names=', preview, re.S).group(1))
NS = '{http://www.w3.org/2000/svg}'

def number(n):
    return f'{n:.5f}'.rstrip('0').rstrip('.') if n else '0'

def point(p):
    return f'CGPoint(x: {number(p[0])}, y: {number(p[1])})'

def path_code(d):
    tokens = re.findall(r'[A-Za-z]|[-+]?(?:\d*\.\d+|\d+\.?\d*)(?:[eE][-+]?\d+)?', d)
    i = 0
    command = None
    current = (0, 0)
    start = current
    control = None
    lines = []
    def pair(relative):
        nonlocal i
        p = (float(tokens[i]), float(tokens[i+1])); i += 2
        return (p[0]+current[0], p[1]+current[1]) if relative else p
    while i < len(tokens):
        if tokens[i].isalpha():
            command = tokens[i]; i += 1
        cmd = command.upper(); rel = command.islower()
        if cmd == 'Z':
            lines.append('p.closeSubpath()'); current = start; control = None; command = None
        elif cmd in ('M', 'L'):
            end = pair(rel)
            lines.append(f'p.{"move" if cmd == "M" else "addLine"}(to: {point(end)})')
            current = end; control = None
            if cmd == 'M': start = end; command = 'l' if rel else 'L'
        elif cmd in ('H', 'V'):
            v = float(tokens[i]); i += 1
            end = (v + current[0] if rel else v, current[1]) if cmd == 'H' else (current[0], v + current[1] if rel else v)
            lines.append(f'p.addLine(to: {point(end)})'); current = end; control = None
        elif cmd == 'Q':
            c = pair(rel); end = pair(rel)
            lines.append(f'p.addQuadCurve(to: {point(end)}, control: {point(c)})'); current = end; control = c
        elif cmd == 'T':
            c = (2*current[0]-control[0], 2*current[1]-control[1]) if control else current
            end = pair(rel)
            lines.append(f'p.addQuadCurve(to: {point(end)}, control: {point(c)})'); current = end; control = c
        elif cmd == 'C':
            c1 = pair(rel); c2 = pair(rel); end = pair(rel)
            lines.append(f'p.addCurve(to: {point(end)}, control1: {point(c1)}, control2: {point(c2)})'); current = end; control = None
        else:
            raise ValueError(f'Unsupported path command {command}')
    return 'Path { p in\n' + ''.join('                '+line+'\n' for line in lines) + '            }'

def color(value):
    value = value.lstrip('#')
    if len(value) == 3: value = ''.join(v*2 for v in value)
    return 'Color(.sRGB, red: '+number(int(value[:2],16)/255)+', green: '+number(int(value[2:4],16)/255)+', blue: '+number(int(value[4:6],16)/255)+', opacity: 1)'

variants = []
for drawing in drawings:
    root = ET.fromstring(drawing)
    gradients = {g.get('id'):g for g in root.iter(NS+'radialGradient')}
    layers = []
    def visit(node, part='body'):
        cls = node.get('class')
        parts = {'floor':'shadow','ornaments':'accent','eyes':'eyes','mouth':'mouth','brows':'brows','tear':'tear','hands':'hands','hand-left':'leftHand','hand-right':'rightHand','cheek':'cheek'}
        part = parts.get(cls,part)
        tag = node.tag.removeprefix(NS)
        if tag in ('defs','radialGradient','stop'): return
        if tag in ('svg','g'):
            for child in node: visit(child,part)
            return
        if tag == 'path': shape = path_code(node.get('d'))
        elif tag in ('ellipse','circle'):
            cx,cy = float(node.get('cx')),float(node.get('cy'))
            rx,ry = (float(node.get('r')),)*2 if tag == 'circle' else (float(node.get('rx')),float(node.get('ry')))
            shape = f'Path(ellipseIn: CGRect(x: {number(cx-rx)}, y: {number(cy-ry)}, width: {number(rx*2)}, height: {number(ry*2)}))'
        else: raise ValueError(tag)
        fill = node.get('fill','#000')
        if fill == 'none': shading = 'nil'
        elif fill.startswith('url('):
            key = fill[5:-1]; gradient = gradients[key]
            stops = []
            for stop in gradient:
                stops.append(f'.init(color: {color(stop.get("stop-color"))}.opacity({number(float(stop.get("stop-opacity","1")))}), location: {number(float(stop.get("offset","0")))})')
            if key.startswith('cheek'):
                center = f'CGPoint(x: {node.get("cx")}, y: {node.get("cy")})'; radius = node.get('rx')
            else: center = 'CGPoint(x: 113, y: 89)'; radius = '160'
            shading = f'.radialGradient(Gradient(stops: [{", ".join(stops)}]), center: {center}, startRadius: 0, endRadius: {radius})'
        else: shading = f'.color({color(fill)})'
        stroke = color(node.get('stroke')) if node.get('stroke') and node.get('stroke') != 'none' else 'nil'
        layers.append(f'        Layer(part: .{part}, path: {shape}, fill: {shading}, stroke: {stroke}, width: {node.get("stroke-width","1")}, opacity: {number(float(node.get("opacity","1")))})')
    visit(root)
    variants.append('    [\n'+',\n'.join(layers)+'\n    ]')
source = '''// Generated by scripts/generate_dumpling_artwork.py from the approved SVG preview.
// Edit the source artwork or generator, then regenerate; no SVG parser ships in the app.
import SwiftUI

enum DumplingArtwork {
    enum Part { case body, shadow, accent, eyes, mouth, brows, tear, hands, leftHand, rightHand, cheek }
    struct Layer {
        let part: Part
        let path: Path
        let fill: GraphicsContext.Shading?
        let stroke: Color?
        let width: CGFloat
        let opacity: Double
    }
    static let moods: [[Layer]] = [
'''+',\n'.join(variants)+'\n    ]\n}\n'
(ROOT / 'Sources/Watch/DumplingArtwork.swift').write_text(source)
print('Generated five layered native dumplings.')
