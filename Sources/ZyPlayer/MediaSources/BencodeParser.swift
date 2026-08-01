import Foundation

/// A simple parser for Bencode used in .torrent files.
struct BencodeParser {
    
    enum BencodeValue {
        case integer(Int)
        case string(String)
        case list([BencodeValue])
        case dictionary([String: BencodeValue])
    }
    
    static func parse(data: Data) -> [String: BencodeValue]? {
        var index = data.startIndex
        
        func parseValue() -> BencodeValue? {
            guard index < data.endIndex else { return nil }
            let byte = data[index]
            
            if byte == UInt8(ascii: "i") {
                return parseInteger()
            } else if byte == UInt8(ascii: "l") {
                return parseList()
            } else if byte == UInt8(ascii: "d") {
                return parseDictionary()
            } else if byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") {
                return parseString()
            }
            return nil
        }
        
        func parseInteger() -> BencodeValue? {
            index = data.index(after: index) // skip 'i'
            guard let end = data[index...].firstIndex(of: UInt8(ascii: "e")) else { return nil }
            let intStr = String(decoding: data[index..<end], as: UTF8.self)
            index = data.index(after: end) // skip 'e'
            if let int = Int(intStr) {
                return .integer(int)
            }
            return nil
        }
        
        func parseString() -> BencodeValue? {
            guard let colon = data[index...].firstIndex(of: UInt8(ascii: ":")) else { return nil }
            let lenStr = String(decoding: data[index..<colon], as: UTF8.self)
            guard let length = Int(lenStr) else { return nil }
            
            let start = data.index(after: colon)
            let end = data.index(start, offsetBy: length, limitedBy: data.endIndex) ?? data.endIndex
            
            let str = String(decoding: data[start..<end], as: UTF8.self)
            index = end
            return .string(str)
        }
        
        func parseList() -> BencodeValue? {
            index = data.index(after: index) // skip 'l'
            var list: [BencodeValue] = []
            while index < data.endIndex, data[index] != UInt8(ascii: "e") {
                if let val = parseValue() {
                    list.append(val)
                } else {
                    return nil
                }
            }
            if index < data.endIndex {
                index = data.index(after: index) // skip 'e'
            }
            return .list(list)
        }
        
        func parseDictionary() -> BencodeValue? {
            index = data.index(after: index) // skip 'd'
            var dict: [String: BencodeValue] = [:]
            while index < data.endIndex, data[index] != UInt8(ascii: "e") {
                guard let keyVal = parseString(), case .string(let key) = keyVal else { return nil }
                guard let val = parseValue() else { return nil }
                dict[key] = val
            }
            if index < data.endIndex {
                index = data.index(after: index) // skip 'e'
            }
            return .dictionary(dict)
        }
        
        if let root = parseValue(), case .dictionary(let dict) = root {
            return dict
        }
        return nil
    }
}
