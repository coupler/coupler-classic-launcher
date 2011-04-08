import java.lang.Character
import java.lang.RuntimeException
import java.lang.ClassCastException

# ganked from http://www.java2s.com/Code/Java/Data-Type/Hexencoderanddecoder.htm
class Hex
  # workaround, see http://groups.google.com/group/mirah/browse_thread/thread/61ca5f5cb41e48fa
  def self.digits
    "0123456789abcdef".toCharArray
  end

  def self.decodeHex(data:char[])
    throws RuntimeException

    len = data.length

    if (len & 0x01) != 0
      raise RuntimeException, "Odd number of characters."
    end

    out = byte[len >> 1]

    i = j = 0
    while j < len
      f = toDigit(data[j], j) << 4
      j += 1
      f = f | toDigit(data[j], j)
      j += 1
      out[i] = byte(f & 0xFF)
      i += 1
    end

    out
  end

  def self.toDigit(ch:char, index:int)
    throws RuntimeException

    digit = Character.digit(ch, 16)
    if digit == -1
      raise RuntimeException, "Illegal hexadecimal charcter #{ch} at index #{index}"
    end

    digit
  end

  def self.encodeHex(data:byte[])
    l = data.length

    out = char[l << 1]

    i = j = 0
    while i < l
      # NOTE: originally this code uses the >>> operator, which is an
      #       unsigned right shift
      out[j] = digits[((0xF0 & data[i]) >> 4) % 16]
      j += 1
      out[j] = digits[0x0F & data[i]]
      j += 1
      i += 1
    end

    out
  end

  def decode(array:byte[])
    throws RuntimeException
    Hex.decodeHex(String.new(array).toCharArray)
  end

  def decode(string:String)
    throws RuntimeException
    Hex.decodeHex(string.toCharArray)
  end

  def decode(object:Object)
    throws RuntimeException

    begin
      charArray = char[].cast(object)
      Hex.decodeHex(charArray)
    rescue ClassCastException => e
      raise RuntimeException, e.getMessage
    end
  end

  def encode(array:byte[])
    String.new(Hex.encodeHex(array)).getBytes
  end

  def encode(string:String)
    Hex.encodeHex(string.getBytes)
  end

  def encode(object:Object)
    throws RuntimeException

    begin
      byteArray = byte[].cast(object)
      Hex.encodeHex(byteArray);
    rescue ClassCastException => e
      raise RuntimeException, e.getMessage
    end
  end
end
