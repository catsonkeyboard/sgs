-- DIY 扩展示例 2：用「技能牌」实现技能（原版最常见的写法）
-- 参考 QSanguosha/extension-doc/4-SkillCard.lua 的制衡技能牌
--
-- 这个例子验证：sgs.CreateSkillCard / Card:clone() / subcards /
-- getSubcards():length() / target_fixed / will_throw 是否能跑通。

diy2 = sgs.Package("skillcard_demo", sgs.Package_GeneralPack)

-- 【自守】：出牌阶段，弃置任意张手牌，然后摸等量的牌（技能牌版本）
ZishouCard = sgs.CreateSkillCard{
	name = "ZishouCard",
	target_fixed = true,
	will_throw = true,
	on_use = function(self, room, source, targets)
		-- will_throw 为 true，作为代价的牌此时已入弃牌堆
		local n = self:getSubcards():length()
		if n > 0 and source:isAlive() then
			source:drawCards(n)
		end
	end,
}

Zishou = sgs.CreateViewAsSkill{
	name = "自守",
	view_filter = function(self, selected, to_select)
		return #selected < 3 and not to_select:isEquipped()
	end,
	view_as = function(self, cards)
		if #cards == 0 then return nil end
		-- 原版惯用写法：先建好一张技能牌，用时克隆一份
		local card = ZishouCard:clone()
		for _, c in ipairs(cards) do
			card:addSubcard(c)
		end
		card:setSkillName(self:objectName())
		return card
	end,
	enabled_at_play = function(self, player)
		return player:getHandcardNum() > 1 and not player:hasUsed("#ZishouCard")
	end,
}

zoushi2 = sgs.General(diy2, "试作武将", "qun", 4)
zoushi2:addSkill(Zishou)

sgs.LoadTranslationTable{
	["skillcard_demo"] = "技能牌测试包",
	["自守"] = "自守",
	[":自守"] = "出牌阶段，你可以弃置至多三张手牌，然后摸等量的牌。",
}

return { diy2 }
