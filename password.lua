-- bizhawk compatibility
if not memory.readword then memory.readword = memory.read_u16_le end
if not memory.readdword then memory.readdword = memory.read_u32_le end
if not memory.writeword then memory.writeword = memory.write_u16_le end
if not memory.writedword then memory.writedword = memory.write_u32_le end


function getFlag(flag)
    local bytepos = bit.rshift(flag, 3)
    local bitpos = bit.band(flag, 7)
    return bit.band(bit.rshift(memory.readbyte(0x02000040 + bytepos), bitpos), 1)
end


function map(array, func)
    local newarray = {}
    for k,v in pairs(array) do table.insert(newarray, func(v)) end
    return newarray
end


function bitarray()  -- data type for storing binary data
    local function write(self, value, size, pos)
        pos = pos or #self.bits+1
        size = size or 1
        for i=1,size do
            self.bits[pos + i-1] = bit.band(bit.rshift(value, size-i), 1)
        end
    end
    local function sub(self, min, max)
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
    local events = {}
    local stats = {}
    local items = {}
    local coins = 0

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

    events = {
        getFlag(0x941),  -- Save Hammet
        getFlag(0x951),  -- Beat Colosso
        getFlag(0x8B3),  -- Hsu Died
        getFlag(0x8D1),  -- Beat Deadbeard
        getFlag(0x81E),  -- Return to Vale
        getFlag(0x868)   -- Return to Vault
    }

    coins = memory.readdword(0x02000250)

    return levels, djinn, events, stats, items, coins
end


function getpassword(passwordtier, levels, djinn, events, stats, items, coins)
    passwordtier = passwordtier:lower()
    local bits = bitarray()

    -- insert 7 bits per level, 7 bits per djinn element
    local levelbits, djinnbits = bitarray(), bitarray()
    for i=4,1,-1 do levelbits:write(levels[i],7) end
    for i=4,1,-1 do djinnbits:write(djinn[i],7) end
    for i=28,12,-8 do bits:write(levelbits:sub(i-7,i),8) end
    bits:write(levelbits:sub(1,4),4); bits:write(djinnbits:sub(25,28),4)
    for i=24,8,-8 do bits:write(djinnbits:sub(i-7,i),8) end
    
    for i=8,1,-1 do bits:write(events[i] or 0) end
    
    local sizes = {bronze=9, silver=39, gold=173}
    if not sizes[passwordtier] then passwordtier = "gold" end
    local size = sizes[passwordtier]

    -- if silver or bronze, insert 8 bits representing which of these items your party has
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
    if passwordtier ~= "bronze" then  -- insert stats
        for i=1,4 do
            local hp, pp, atk, def, agi, lck = unpack(stats[i])
            bits:write(hp, 11); bits:write(pp, 11); bits:write(atk, 10)
            bits:write(def, 10); bits:write(agi, 10); bits:write(lck, 8)
        end
    end
    if passwordtier == "gold" then  -- insert items and coins
        bits:write(0, 8)
        local counter = 0
        for i=1,4 do
            for j, item in pairs(items[i]) do
                local id = bit.band(item, 0x1FF)
                bits:write(id, 9)
                counter = counter + 1
                if counter == 7 then bits:write(0); counter = 0 end  -- append a 0 bit every 7 items
            end
        end
        local stackables = {  -- list of all stackable items in GS1
            0xB4, 0xB5, 0xB6, 0xB7, 0xBA, 0xBB, 0xBC, 0xBD,
            0xBF, 0xC0, 0xC1, 0xC2, 0xC3, 0xC4, 0xE2, 0xE3,
            0xE4, 0xE5, 0xEC, 0xEE, 0xEF, 0xF0, 0xF1,
        }
        for i=1,4 do  -- insert quantities of stackable items for each adept
            for j=1,#stackables do
                local quantity = 0
                for k, item in pairs(items[i]) do
                    local id = bit.band(item, 0x1FF)
                    if id == stackables[j] then quantity = bit.rshift(item, 11) end
                end
                bits:write(quantity, 5)
            end
        end
        bits:write(coins, 24)
    end

    bits:write(0, 8*size - #bits.bits)  -- append 0's until reaching the correct password size

    -- Encrypt with key 0x1021
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

    -- split into 6-bit entries
    local out = {}
    local acc = 0
    for i=1, (size+2)*8, 6 do
        local entry = bits:sub(i, i+5)
        table.insert(out, entry)
        acc = acc + entry
        if #out % 10 == 9 then  -- insert checksum for each line
            table.insert(out, bit.band(acc, 0x3F))
            acc = 0
        end
    end
    for i=1,#out do
        out[i] = bit.band(out[i] + i-1, 0x3f)
    end

    local chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789abcdefghijkmnpqrstuvwxyz!?#&$%+="
    for i=1,#out do out[i] = chars:sub(out[i]+1, out[i]+1) end
    local password = {}
    for i=1, #out do
        table.insert(password, out[i])
        if i % 10 == 0 then table.insert(password, "\n")
        elseif i % 5 == 0 then table.insert(password, " ")
        end
    end

    return table.concat(password)
end


function filecheck(filename)
    local file = io.open(filename, "r")
    if file ~= nil then
        file:close()
        return true
    else
        return false
    end
end

function writefile(filename, data)
    local file = assert(io.open(filename, "w"))
    file:write(data)
    file:close()
end

function readfile(filename)
    local file = io.open(filename, "r")
    if file ~= nil then
        local data = file:read("*all")
        file:close()
        return data
    end
end


function inputPassword(password)  -- Thanks to Straylite and Teaman for this function
    local chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789abcdefghijkmnpqrstuvwxyz!?#&$%+="
    local addr = 0x0200A74A
    for i = 0, 259 do memory.writebyte(addr + i, 0x63) end
    for i = 1, #password do
        local letterID = string.find(chars, password:sub(i,i), 1, true)
        if letterID ~= nil then --Skip spaces, line breaks, etc.
            memory.writebyte(addr, letterID - 1)
            addr = addr + 1
            if addr == 0x0200A84E then break end
        end
    end
end


function exportData(filename)
    local levels, djinn, events, stats, items, coins = getdata()
    local data = ""
        .. "Levels\n"
        .. string.format("%d\t%d\t%d\t%d", unpack(levels))
        .. "\n\nDjinn\nVenus\tMercury\tMars\tJupiter\n"
        .. string.format("%02X\t%02X\t%02X\t%02X", unpack(djinn))
        .. "\n\nEvents\n"
        .. string.format("%d\t%d\t%d\t%d\t%d\t%d", unpack(events))
        .. "\n\nStats\nIsaac\tGaret\tIvan\tMia"
    for i=1,6 do
        data = string.format("%s\n%d\t%d\t%d\t%d", data, stats[1][i], stats[2][i], stats[3][i], stats[4][i])
    end
    data = data.."\n\nItems\nIsaac\tGaret\tIvan\tMia"
    for i=1,15 do
        data = string.format("%s\n%04X\t%04X\t%04X\t%04X", data, items[1][i], items[2][i], items[3][i], items[4][i])
    end
    data = data.."\n\nCoins\n"..coins
    writefile(filename, data)
end


function importData(filename)
    local data = readfile(filename)
    local levels = map({data:match("Levels\n(.-)\t(.-)\t(.-)\t(.-)\n")}, tonumber)
    local djinn = {data:match("Djinn\n.-\n(.-)\t(.-)\t(.-)\t(.-)\n")}
    for k,v in pairs(djinn) do djinn[k] = tonumber("0x"..v) end
    local events = map({data:match("Events\n(.-)\t(.-)\t(.-)\t(.-)\t(.-)\t(.-)\n")}, tonumber)
    local stats = {{}, {}, {}, {}}
    for line in data:match("Stats\n.-\n(.-)\n\n"):gmatch("[^\n]+") do
        for i,s in pairs({line:match(string.rep("([^\t]+)\t?",4))}) do 
            table.insert(stats[i], tonumber(s))
        end
    end
    local items = {{}, {}, {}, {}}
    for line in data:match("Items\n.-\n(.-)\n\n"):gmatch("[^\n]+") do
        for i,s in pairs({line:match(string.rep("([^\t]+)\t?",4))}) do 
            table.insert(items[i], tonumber("0x"..s))
        end
    end
    local coins = tonumber(data:match("Coins\n(.-)$"))
    return levels, djinn, events, stats, items, coins
end


function timedMessage(x, y)
    local function draw(self)
        if self.time > 0 then
            gui.text(self.x, self.y, self.message)
            self.time = self.time - 1
        end
    end
    local function new(self, message, time)
        self.message = message
        self.time = time
    end
    return {x=x, y=y, message="", time=0, draw=draw, new=new}
end


print("Golden Sun Password Transfer")
print("")
print("shift+C to copy password (GS1 only)")
print("shift+V to paste password directly into game (GS2 only)")
print("shift+R to cycle through gold, silver, bronze")
print("shift+P to print most recent password to the console")
print("shift+O to open password file for direct editing")
print("    paste the password into the text file, save it, then use shift+V")


key = {}
guimessage = timedMessage(2, 2)

passwordtier = 0
tierlist = {[0]="Gold", "Silver", "Bronze"}
guimessage:new(tierlist[passwordtier].." password selected", 120)

if not filecheck("gspassword.txt") then
    io.open("gspassword.txt", "w"):close()
end
password = readfile("gspassword.txt")


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

    if key["shift"] or key["ShiftLeft"] or key["ShiftRight"] or key["LeftShift"] or key["RightShift"] then
        if key["C"] == 1 then
            if ROM == "Golden_Sun_A" then
                password = getpassword(tierlist[passwordtier], getdata())
                guimessage:new("saved "..tierlist[passwordtier].." password", 120)
                if filecheck("password.lua") then  -- check that working directory has not changed during runtime
                    writefile("gspassword.txt", password)
                end
            else
                guimessage:new("Error: Golden Sun not running", 120)
            end
        end
        if key["R"] == 1 then
            passwordtier = (passwordtier + 1) % 3
            guimessage:new(tierlist[passwordtier].." password selected", 120)
        end
        if key["V"] == 1 then
            data = readfile("gspassword.txt")
            if data and data ~= "" then password = data end
            if ROM == "GOLDEN_SUN_B" then
                if memory.readword(0x02000420) == 0 then
                    inputPassword(password)
                end
            end
        end
        if key["P"] == 1 then
            data = readfile("gspassword.txt")
            if data and data ~= "" then password = data end
            print("")
            for line in string.gmatch(password, "[^\n]+") do
                print(line)
            end
        end
        if key["O"] == 1 then
            if filecheck("password.lua") then
                if not filecheck("gspassword.txt") then
                    io.open("gspassword.txt", "w"):close()
                end
                os.execute("start gspassword.txt")
            else
                print("Error: working directory changed during runtime. Restart script to fix")
            end
        end
        if key["E"] == 1 then
            if filecheck("password.lua") then
                exportData("gspassword_export.txt")
                guimessage:new("Exported data", 120)
            else
                print("Error: working directory changed during runtime. Restart script to fix")
            end
        end
        if key["I"] == 1 then
            if filecheck("gspassword_export.txt") then
                password = getpassword(tierlist[passwordtier], importData("gspassword_export.txt"))
                if filecheck("password.lua") then
                    writefile("gspassword.txt", password)
                end
                guimessage:new("Imported data", 120)
            else
                print("Error: could not find \"gspassword_export.txt\"")
            end
        end
    end

    guimessage:draw()
    emu.frameadvance()
end
