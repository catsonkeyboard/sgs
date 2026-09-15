-- 武将技能说明与共享弹层。
-- 核心技能对象只保存执行逻辑与显示名；这里集中保存面向玩家的简明说明，
-- 本地牌桌和联机牌桌共用，避免两套 UI 文案漂移。
local SkillDesc = {}

SkillDesc.TEXT = {
  ["奸雄"] = "当你受到伤害后，你可以获得造成此伤害的牌。",
  ["护驾"] = "主公技：当你需要使用或打出【闪】时，可令其他魏势力角色依次提供一张【闪】。",
  ["反馈"] = "当你受到伤害后，你可以获得伤害来源的一张牌。",
  ["鬼才"] = "一名角色的判定牌生效前，你可以打出一张手牌代替之。",
  ["刚烈"] = "受到伤害后可判定；若不为红桃，伤害来源弃两张手牌或受到你造成的1点伤害。",
  ["突袭"] = "摸牌阶段，你可少摸任意张牌，并获得等量其他角色各一张手牌。",
  ["裸衣"] = "摸牌阶段少摸一张；本回合你使用【杀】或【决斗】造成的伤害+1。",
  ["天妒"] = "你的判定牌生效后，你可以获得之。",
  ["遗计"] = "每受到1点伤害后，观看牌堆顶两张牌，并将其任意分配给任意角色。",
  ["倾国"] = "你可以将一张黑色手牌当【闪】使用或打出。",
  ["洛神"] = "准备阶段可反复判定：黑色牌收入手中；出现红色牌时停止。",
  ["仁德"] = "出牌阶段可将任意张手牌交给其他角色；本阶段累计给出两张时回复1点体力。",
  ["激将"] = "主公技：当你需要【杀】时，可令其他蜀势力角色依次提供一张【杀】。",
  ["武圣"] = "你可以将一张红色牌当【杀】使用或打出。",
  ["咆哮"] = "锁定技：你使用【杀】无次数限制。",
  ["观星"] = "准备阶段观看牌堆顶X张牌，并以任意顺序置于牌堆顶或牌堆底（X至多为5）。",
  ["空城"] = "锁定技：若你没有手牌，你不能成为【杀】或【决斗】的目标。",
  ["龙胆"] = "你可以将【杀】当【闪】、【闪】当【杀】使用或打出。",
  ["马术"] = "锁定技：你计算与其他角色的距离-1。",
  ["铁骑"] = "你使用【杀】指定目标后可判定；若为红色，该目标不能使用【闪】响应。",
  ["集智"] = "你使用非延时锦囊牌时，可以摸一张牌。",
  ["奇才"] = "锁定技：你使用锦囊牌无距离限制。",
  ["制衡"] = "出牌阶段限一次，你可以弃置任意数量的手牌或装备，然后摸等量的牌。",
  ["救援"] = "主公技，每回合限一次：其他吴势力角色对濒死的你使用【桃】时，你额外回复1点体力。",
  ["奇袭"] = "你可以将一张黑色牌当【过河拆桥】使用。",
  ["克己"] = "若你于出牌阶段未使用或打出【杀】，可以跳过弃牌阶段。",
  ["苦肉"] = "出牌阶段，你可以失去1点体力，然后摸两张牌。",
  ["英姿"] = "摸牌阶段，你可以额外摸一张牌。",
  ["反间"] = "出牌阶段限一次，令一名角色猜一种花色并获得你选择的一张手牌；若猜错，其受到1点伤害。",
  ["国色"] = "你可以将一张方块牌当【乐不思蜀】使用。",
  ["流离"] = "成为【杀】的目标时，你可以弃一张牌，将此【杀】转移给攻击范围内另一名合法角色。",
  ["谦逊"] = "锁定技：你不能成为【顺手牵羊】和【乐不思蜀】的目标。",
  ["连营"] = "当你失去最后一张手牌时，可以摸一张牌。",
  ["结姻"] = "出牌阶段限一次，弃两张手牌并选择一名已受伤男性角色，你与其各回复1点体力。",
  ["枭姬"] = "当你失去装备区里的一张牌后，可以摸两张牌。",
  ["青囊"] = "出牌阶段限一次，弃一张手牌并令一名已受伤角色回复1点体力。",
  ["急救"] = "你的回合外，可以将一张红色牌当【桃】使用。",
  ["无双"] = "锁定技：你的【杀】需两张【闪】抵消；与你【决斗】的角色每次需打出两张【杀】。",
  ["离间"] = "出牌阶段限一次，弃一张牌，令一名男性角色视为对另一名男性角色使用不可被无懈的【决斗】。",
  ["闭月"] = "结束阶段，你可以摸一张牌。",

  ["短兵"] = "你使用【杀】时，可额外指定一名与你距离为1且尚未成为目标的角色。",
  ["奋迅"] = "出牌阶段限一次，弃一张牌并选择一名角色，本回合你计算与其距离视为1。",
  ["骁果"] = "其他角色结束阶段，你可弃一张基本牌，令其弃一张装备牌，否则其受到1点伤害。",
  ["直谏"] = "出牌阶段限一次，将一张装备牌置入其他角色装备区，然后摸一张牌。",
  ["固政"] = "其他角色弃牌阶段结束时，可归还其一张本阶段弃牌，并获得其余弃牌。",
  ["强袭"] = "出牌阶段限一次，你可以弃一张武器牌或失去1点体力，对攻击范围内一名角色造成1点伤害。",
  ["享乐"] = "锁定技：你体力大于1时成为【杀】的目标，使用者须弃一张手牌，否则此【杀】无效。",
  ["八阵"] = "锁定技：若装备区没有防具，视为装备【八卦阵】。",
  ["火计"] = "你可以将一张红色牌当【火攻】使用。",
  ["看破"] = "你可以将一张黑色牌当【无懈可击】使用。",
  ["不屈"] = "濒死时翻开牌堆顶牌作为“创”；点数不重复则暂时不会死亡。",
  ["神速"] = "你可跳过判定/摸牌阶段或出牌/弃牌阶段，视为使用一张无距离限制的【杀】。",
  ["天义"] = "出牌阶段限一次与一名有手牌角色拼点；赢则本回合【杀】强化，输则不能使用【杀】。",
  ["名士"] = "锁定技：无手牌角色对你造成的伤害-1。",
  ["礼让"] = "弃牌阶段结束时，可将本阶段弃置的牌交给其他角色。",
  ["英魂"] = "准备阶段，若你已受伤，可令一名角色摸X弃一或摸一弃X（X为已损失体力）。",
  ["祸首"] = "锁定技：你免疫【南蛮入侵】，且其他角色使用的【南蛮入侵】伤害来源视为你。",
  ["再起"] = "摸牌阶段，若已受伤可展示X张牌：红桃回复体力，其余收入手中。",
  ["红颜"] = "锁定技：你的黑桃牌视为红桃。",
  ["天香"] = "受到伤害时，可弃一张红桃手牌并转移伤害；受伤角色随后按已损失体力摸牌。",
  ["猛进"] = "你使用的【杀】被【闪】抵消后，可以弃置目标一张牌。",
  ["连环"] = "你可以将梅花牌当【铁索连环】使用或重铸。",
  ["涅槃"] = "限定技：濒死时弃置区域内所有牌，复原状态并回复至3点体力，再摸三张牌。",
  ["雷击"] = "你使用或打出【闪】后，可令一名角色判定；黑桃则其受到2点雷电伤害。",
  ["鬼道"] = "一名角色判定牌生效前，你可以打出一张黑色牌替换之，并获得原判定牌。",
  ["巧变"] = "你可弃一张手牌跳过一个阶段，并在部分阶段执行移动牌等替代效果。",
  ["断粮"] = "你可以将一张黑色基本牌或装备牌当【兵粮寸断】使用；对距离2的角色也可使用。",
  ["行殇"] = "其他角色死亡时，你可以获得其所有牌。",
  ["放逐"] = "受到伤害后，可令一名其他角色摸X张牌并翻面（X为你已损失体力）。",
  ["据守"] = "结束阶段，你可以摸三张牌，然后翻面。",
  ["狂斧"] = "你使用【杀】造成伤害后，可弃置目标装备区的一张牌或将其一张装备移至自己装备区。",
  ["淑慎"] = "出牌阶段，你可以弃一张黑色手牌，令一名角色回复1点体力。",
  ["死谏"] = "失去最后一张手牌时，可以弃置一名其他角色的一张牌。",
  ["随势"] = "锁定技：队友进入濒死时你摸一张牌；队友死亡时你失去1点体力。",
  ["巨象"] = "锁定技：你免疫【南蛮入侵】，并可获得进入弃牌堆的【南蛮入侵】。",
  ["烈刃"] = "你使用【杀】造成伤害后，可与受伤角色拼点；若赢，获得其一张牌。",
  ["双刃"] = "准备阶段可与一名男性角色拼点；赢则视为对其或其邻座使用【杀】，输则结束出牌阶段。",
  ["驱虎"] = "出牌阶段限一次，与体力值大于你的一名角色拼点；赢则令其伤害指定角色，输则其伤害你。",
  ["节命"] = "每受到1点伤害后，可令一名角色将手牌补至其体力上限（至多补五张）。",
  ["悲歌"] = "其他角色受到【杀】伤害后，可弃一张牌令其判定，并按花色获得不同效果。",
  ["断肠"] = "锁定技：杀死你的角色失去其所有武将技能。",
  ["乱击"] = "你可以将两张相同花色的手牌当【万箭齐发】使用。",
  ["完杀"] = "锁定技：你的回合内，除濒死角色外，其他角色不能使用【桃】。",
  ["帷幕"] = "锁定技：你不能成为黑色锦囊牌的目标。",
  ["乱武"] = "限定技：令所有其他角色依次对距离最近的角色使用【杀】，否则失去1点体力。",
  ["双雄"] = "摸牌阶段可改为判定并获得判定牌；本回合可将与其颜色不同的手牌当【决斗】。",
  ["雄异"] = "限定技：出牌阶段令己方角色各摸三张牌；若己方人数最少，你回复1点体力。",
  ["狂骨"] = "锁定技：你对距离1以内的角色造成1点伤害后，回复1点体力。",
  ["好施"] = "摸牌阶段可额外摸两张；若手牌多于五张，将一半手牌交给全场手牌最少角色。",
  ["缔盟"] = "出牌阶段限一次，弃置等同两名其他角色手牌差的牌，交换其手牌。",
  ["烈弓"] = "你使用【杀】指定目标后，若其手牌数不小于你的体力或不大于你的攻击范围，其不能出【闪】。",
}

local function baseName(name)
  name = tostring(name or "未知技能")
  return name:match("^(.-)·") or name
end

function SkillDesc.entriesFromSkills(skills)
  local out, seen = {}, {}
  for _, skill in ipairs(skills or {}) do
    local name = baseName(skill.zh or skill.name)
    if not seen[name] then
      seen[name] = true
      out[#out + 1] = {
        name = name,
        desc = skill.description or skill.desc or SkillDesc.TEXT[name]
          or "该技能暂无详细说明。",
      }
    end
  end
  return out
end

function SkillDesc.entriesFromNames(names)
  local out, seen = {}, {}
  for _, raw in ipairs(names or {}) do
    local name = baseName(raw)
    if not seen[name] then
      seen[name] = true
      out[#out + 1] = { name = name, desc = SkillDesc.TEXT[name] or "该技能暂无详细说明。" }
    end
  end
  return out
end

function SkillDesc.open(playerName, generalName, entries)
  return {
    player_name = playerName or "未知角色",
    general_name = generalName or "未知武将",
    entries = entries or {},
  }
end

function SkillDesc.layout(popup)
  local sw, sh = love.graphics.getDimensions()
  local count = math.max(1, #(popup and popup.entries or {}))
  local w = math.min(680, sw - 80)
  local h = math.min(sh - 60, 112 + count * 68)
  local x, y = (sw - w) / 2, (sh - h) / 2
  return {
    x = x, y = y, w = w, h = h,
    close = { x = x + w - 94, y = y + 18, w = 72, h = 30 },
  }
end

function SkillDesc.shouldClose(popup, x, y)
  local box = SkillDesc.layout(popup)
  local c = box.close
  if x >= c.x and x <= c.x + c.w and y >= c.y and y <= c.y + c.h then return true end
  return x < box.x or x > box.x + box.w or y < box.y or y > box.y + box.h
end

function SkillDesc.draw(popup, font, font_mid, font_sm)
  if not popup then return end
  local sw, sh = love.graphics.getDimensions()
  local box = SkillDesc.layout(popup)
  love.graphics.setColor(0, 0, 0, 0.68)
  love.graphics.rectangle("fill", 0, 0, sw, sh)
  love.graphics.setColor(0.10, 0.14, 0.10, 0.98)
  love.graphics.rectangle("fill", box.x, box.y, box.w, box.h, 12, 12)
  love.graphics.setColor(0.82, 0.68, 0.30)
  love.graphics.rectangle("line", box.x, box.y, box.w, box.h, 12, 12)

  love.graphics.setFont(font_mid or font)
  love.graphics.setColor(1, 0.90, 0.58)
  love.graphics.print(string.format("%s · %s", popup.player_name, popup.general_name),
    box.x + 24, box.y + 20)
  love.graphics.setFont(font_sm or font)
  love.graphics.setColor(0.72, 0.78, 0.70)
  love.graphics.print("武将技能说明", box.x + 24, box.y + 51)

  local entries = popup.entries or {}
  if #entries == 0 then
    love.graphics.setColor(0.82, 0.84, 0.78)
    love.graphics.print("该武将没有技能。", box.x + 24, box.y + 84)
  else
    for i, entry in ipairs(entries) do
      local ey = box.y + 78 + (i - 1) * 68
      love.graphics.setFont(font or font_sm)
      love.graphics.setColor(0.96, 0.76, 0.28)
      love.graphics.print("【" .. entry.name .. "】", box.x + 24, ey)
      love.graphics.setFont(font_sm or font)
      love.graphics.setColor(0.90, 0.92, 0.86)
      love.graphics.printf(entry.desc, box.x + 112, ey + 1, box.w - 142, "left")
    end
  end

  local c = box.close
  love.graphics.setColor(0.28, 0.38, 0.26)
  love.graphics.rectangle("fill", c.x, c.y, c.w, c.h, 6, 6)
  love.graphics.setColor(1, 1, 1)
  love.graphics.setFont(font_sm or font)
  love.graphics.printf("关闭", c.x, c.y + 7, c.w, "center")
end

return SkillDesc
