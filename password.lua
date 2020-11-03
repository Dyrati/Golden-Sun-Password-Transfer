if not memory.readword then memory.readword = memory.read_u16_le end
if not memory.readdword then memory.readdword = memory.read_u32_le end
if not memory.writeword then memory.writeword = memory.write_u16_le end
if not memory.writedword then memory.writedword = memory.write_u32_le end


function getFlag(flag)
    local bytepos = bit.rshift(flag, 3)
    local bitpos = bit.band(flag, 7)
    return bit.band(bit.rshift(memory.readbyte(0x02000040 + bytepos), bitpos), 1)
end


function bitarray()
    function write(self, value, size, pos)
        pos = pos or #self.bits+1
        size = size or 1
        for i=1,size do
            self.bits[pos + i-1] = bit.band(bit.rshift(value, size-i), 1)
        end
    end
    function sub(self, min, max)
        if max == nil then return self.bits[min] or 0 end
        local acc = 0
        for i=0,max-min do
            acc = 2*acc + (self.bits[min+i] or 0)
        end
        return acc
    end
    return {bits={}, write=write, sub=sub}
end


function getdata()
    local levels = {}
    local djinn = {0, 0, 0, 0}
    local events = 0
    local stats = {}
    local items = {}
    local coins = 0

    events = bit.bor(events, bit.lshift(getFlag(0x941), 0))
    events = bit.bor(events, bit.lshift(getFlag(0x951), 1))
    events = bit.bor(events, bit.lshift(getFlag(0x8B3), 2))
    events = bit.bor(events, bit.lshift(getFlag(0x8D1), 3))
    events = bit.bor(events, bit.lshift(getFlag(0x81E), 4))
    events = bit.bor(events, bit.lshift(getFlag(0x868), 5))
    coins = memory.readdword(0x02000250)

    for i=0,3 do
        local base = 0x02000500 + 0x14C*i
        table.insert(levels, memory.readbyte(base + 0xF))
        for j=0,3 do
            djinn[j+1] = bit.bor(djinn[j+1], memory.readdword(base + 0xF8 + 4*j))
        end
        local hp = memory.readword(base + 0x10)
        local pp = memory.readword(base + 0x12)
        local atk = memory.readword(base + 0x18)
        local def = memory.readword(base + 0x1A)
        local agi = memory.readword(base + 0x1C)
        local lck = memory.readbyte(base + 0x1E)
        table.insert(stats, {hp, pp, atk, def, agi, lck})
        
        local pcitems = {}
        for j=0,14 do
            table.insert(pcitems, memory.readword(base + 0xd8 + 2*j))
        end
        table.insert(items, pcitems)
    end

    return levels, djinn, events, stats, items, coins
end


function getpassword(passwordtier, levels, djinn, events, stats, items, coins)
    passwordtier = passwordtier:lower()
    local bits = bitarray()

    local tmparray = bitarray()
    for i=4,1,-1 do tmparray:write(djinn[i], 7) end
    for i=4,1,-1 do tmparray:write(levels[i], 7) end
    local swap1, swap2 = tmparray:sub(25,28), tmparray:sub(29,32)
    tmparray:write(swap2, 4, 25); tmparray:write(swap1, 4, 29)
    for i=56,1,-8 do bits:write(tmparray:sub(i-7,i), 8) end
    bits:write(events, 8)
    
    local sizes = {bronze=9, silver=39, gold=173}
    if not sizes[passwordtier] then passwordtier = "gold" end
    local size = sizes[passwordtier]

    if passwordtier ~= "gold" then
        local psyitems = {0xC8, 0xC9, 0xCA, 0xCB, 0xCC, 0xCD, 0xCE, 0xCF}
        local flags = 0
        for i=1,4 do
            for _,item in pairs(items[i]) do
                local id = bit.band(item, 0x1FF)
                for j=0,7 do
                    if id == psyitems[j+1] then flags = bit.bor(flags, 2^j) end
                end
            end
        end
        bits:write(flags, 8)
    end
    if passwordtier ~= "bronze" then
        for i=1,4 do
            local hp, pp, atk, def, agi, lck = unpack(stats[i])
            bits:write(hp, 11); bits:write(pp, 11); bits:write(atk, 10)
            bits:write(def, 10); bits:write(agi, 10); bits:write(lck, 8)
        end
    end
    if passwordtier == "gold" then
        bits:write(0, 8)
        local counter = 0
        local stackables = {
            0xB4, 0xB5, 0xB6, 0xB7, 0xBA, 0xBB, 0xBC, 0xBD,
            0xBF, 0xC0, 0xC1, 0xC2, 0xC3, 0xC4, 0xE2, 0xE3,
            0xE4, 0xE5, 0xEC, 0xEE, 0xEF, 0xF0, 0xF1,
        }
        local quantities = {}
        for i=1,4 do
            local pcquantities = {}
            for j, item in pairs(items[i]) do
                local id, quantity = bit.band(item, 0x1FF), bit.rshift(item, 11)
                bits:write(id, 9)
                counter = counter + 1
                if counter == 7 then bits:write(0); counter = 0 end
                for k, stackid in pairs(stackables) do
                    if not pcquantities[k] then pcquantities[k] = 0 end
                    if id == stackid then pcquantities[k] = quantity end
                end
            end
            table.insert(quantities, pcquantities)
        end
        for i=1,4 do
            for _,quantity in pairs(quantities[i]) do
                bits:write(quantity, 5)
            end
        end
        bits:write(coins, 24)
    end

    bits:write(0, 8*size - #bits.bits)
    local xsum = 0xFFFF
    for i=0,size-1 do
        local byte = bits:sub(8*i+1, 8*i+8)
        xsum = bit.bxor(xsum, bit.lshift(byte, 8))
        for j=1,8 do
            if bit.band(xsum, 0x8000) ~= 0 then
                xsum = bit.lshift(xsum, 1) + 0xFFFFEFDF
            else
                xsum = bit.lshift(xsum, 1)
            end
        end
    end
    xsum = bit.band(bit.bnot(xsum), 0xFFFF)
    bits:write(bit.rshift(xsum, 8), 8)
    bits:write(bit.band(xsum, 0xFF), 8)

    local xorvalue = bit.band(xsum, 0xFF)
    for i=0,size do
        local byte = bits:sub(8*i+1, 8*i+8)
        bits:write(bit.bxor(byte, xorvalue), 8, 8*i+1)
    end

    local out = bitarray()
    local count = 0
    local acc = 0
    local i = 0
    while i < (size+2)*8 do
        local entry = bits:sub(i+1, i+6)
        out:write(entry, 8)
        count = count + 1
        acc = acc + entry
        if count % 10 == 9 then
            out:write(bit.band(acc, 0x3F), 8)
            acc = 0
            count = count + 1
        end
        i = i + 6
    end
    for i=0,count-1 do
        byte = out:sub(8*i+1, 8*i+8)
        out:write(bit.band(byte+i, 0x3f), 8, 8*i+1)
    end

    local chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789abcdefghijkmnpqrstuvwxyz!?#&$%+="
    local password = {}
    for i=0,count-1 do
        local charpos = out:sub(8*i+1, 8*i+8) + 1
        table.insert(password, chars:sub(charpos, charpos))
    end
    return table.concat(password)
end


function writefile(filename, data)
    local file = assert(io.open(filename, "w"))
    file:write(data)
    file:close()
end

function readfile(filename)
    local file = assert(io.open(filename, "r"))
    local data = file:read("*all")
    file:close()
    return data
end

function inputPassword(password)  -- Thanks to Straylite and Teaman for this function
    local chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789abcdefghijkmnpqrstuvwxyz!?#&$%+="
    local addr = 0x0200A74A
    for i = 1, #password do
        local letterID = string.find(chars, password:sub(i,i), 1, true)
        if letterID ~= nil then --Skip spaces, line breaks, etc.
            memory.writebyte(addr, letterID - 1)
            addr = addr + 1
        end
    end
end

function timedMessage(x, y)
    function draw(self)
        if self.time > 0 then
            gui.text(self.x, self.y, self.message)
            self.time = self.time - 1
        end
    end
    function new(self, message, time)
        self.message = message
        self.time = time
    end
    return {x=x, y=y, message="", time=0, draw=draw, new=new}
end


print("Golden Sun Password Generator")
print("")
print("shift+C to copy password")
print("shift+R to cycle through gold, silver, bronze")
print("shift+V to paste password directly into game")
print("shift+P to print password to the console")
print("")

key = {}
guimessage = timedMessage(2, 2)

passwordtier = 0
tierlist = {[0]="gold", "silver", "bronze"}
guimessage:new(tierlist[passwordtier].." password selected", 120)
password = ""

while true do
    tmpkeys = input.get()
    for k, v in pairs(tmpkeys) do
        key[k] = (key[k] or 0) + 1
    end
    for k, v in pairs(key) do
        if not tmpkeys[k] then key[k] = nil end
    end

    ROM = ""
    for i=0,11 do
        ROM = ROM..string.char(memory.readbyte(0x080000A0+i))
    end

    if key["shift"] or key["ShiftLeft"] or key["ShiftRight"] then
        if key["C"] == 1 then
            if ROM == "Golden_Sun_A" then
                password = getpassword(tierlist[passwordtier], getdata())
                writefile("gspassword.txt", password)
                guimessage:new("saved "..tierlist[passwordtier].." password", 120)
            else
                guimessage:new("Error: Golden Sun not running", 120)
            end
        end
        if key["R"] == 1 then
            passwordtier = (passwordtier + 1) % 3
            guimessage:new(tierlist[passwordtier].." password selected", 120)
        end
        if key["V"] == 1 then
            if password == "" then password = readfile("gspassword.txt") end
            if ROM == "GOLDEN_SUN_B" then
                if memory.readword(0x02000420) == 0 then
                    inputPassword(password)
                end
            end
        end
        if key["P"] == 1 then
            if password == "" then password = readfile("gspassword.txt") end
            for i=1,#password,10 do
                print(password:sub(i, i+4), password:sub(i+5, i+9))
            end
        end
    end

    guimessage:draw()
    emu.frameadvance()
end
