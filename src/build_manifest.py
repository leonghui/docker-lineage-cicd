#!/usr/bin/env python

from xml.dom import minidom
import xml.etree.ElementTree as ET
import argparse

try:
    from urllib.request import urlopen
except ImportError:
    from urllib2 import urlopen

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description='Build an Android repo manifest')
    parser.add_argument('url', type=str, help='URL of the source manifest')
    parser.add_argument('out', type=str, help='Output path')
    parser.add_argument('--remote', type=str, help='Remote URL')
    parser.add_argument('--remotename', type=str, help='Remote name')

    args = parser.parse_args()

    source_manifest = urlopen(args.url).read()

    xmlin = ET.fromstring(source_manifest)
    xmlout = ET.Element("manifest")

    if args.remote:
        ET.SubElement(xmlout, 'remote', attrib={"name": args.remotename,
                                                "fetch": args.remote})

    for child in xmlin:
        if child.tag == "project":
            attributes = {}
            attributes["name"] = child.attrib["name"]

            if "path" in child.attrib:
                attributes["path"] = child.attrib["path"]

            if args.remote:
                attributes["remote"] = args.remotename

            ET.SubElement(xmlout, 'project', attrib=attributes)

    xmlstr = minidom.parseString(ET.tostring(xmlout)).toprettyxml(indent="  ", encoding="UTF-8")
    with open(args.out, "w") as f:
        f.write(xmlstr)
