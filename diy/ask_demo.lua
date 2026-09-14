-- DIY 扩展示例 3：询问类 API（askForPindian / askForAG / askForYiji 等）
--
-- 覆盖：触发技里做拼点、摸牌、分牌、设置属性，验证兼容层的 room:* 调用面。
-- 参考 extension-doc/3-TriggerSkill.lua 与 4-SkillCard.lua。

diy3 = sgs.Package("ask_demo", sgs.Package_GeneralPack)

-- 【试炼】：出牌阶段，与一名角色拼点，赢则摸两张并交给队友，输则失去 1 点体力
Shilian = sgs.CreateTriggerSkill{
	name = "试炼",
	events = { sgs.EventPhaseStart },
	frequency = sgs.Skill_Frequent,
	can_trigger = function(self, event, room, player, data)
		if not data then return false end
		if data.player ~= player then return false end
		if data.phase ~= "play" then return false end
		if #player:getHandcards() == 0 then return false end
		for _, p in ipairs(room:getOtherPlayers(player)) do
			if #p:getHandcards() > 0 then return true end
		end
		return false
	end,
	on_cost = function(self, event, room, player, data)
		return room:askForSkillInvoke(player, self:objectName())
	end,
	on_effect = function(self, event, room, player, data)
		local target = room:askForPlayerChosen(player, room:getOtherPlayers(player), self:objectName())
		if not target then return false end

		-- 拼点：原版返回 PindianStruct，脚本读 from_number/to_number
		local pd = room:askForPindian(player, target, self:objectName())
		if not pd then return false end

		if pd.success then
			room:drawCards(player, 2)
			room:log("拼点获胜，摸两张牌")
			-- 把摸到的牌交给一名其他角色（验证 askForYiji）
			if #player:getHandcards() > 0 then
				room:askForYiji(player, { player:getHandcards()[1] }, self:objectName())
			end
		else
			room:loseHp(player, 1)
			room:log("拼点失败，失去 1 点体力")
		end
		return false
	end,
}

shilian_general = sgs.General(diy3, "试炼武将", "qun", 4)
shilian_general:addSkill(Shilian)

sgs.LoadTranslationTable{
	["ask_demo"] = "询问测试包",
	["试炼"] = "试炼",
	[":试炼"] = "出牌阶段，你可以与一名其他角色拼点，若你赢，你摸两张牌然后将一张牌交给一名其他角色；若你输，你失去1点体力。",
}

return { diy3 }
