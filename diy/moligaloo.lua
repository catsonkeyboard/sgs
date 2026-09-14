-- DIY 扩展示例：改编自 QSanguosha/extension-doc/1-Start.lua
-- 这一份用来验证 sgs.* 兼容层：Package / General / OneCardViewAsSkill /
-- filter_pattern / cloneCard / LoadTranslationTable / 触发技 是否都能跑通。

extension = sgs.Package("moligaloo", sgs.Package_GeneralPack)

-- 时迁：梅花手牌当【顺手牵羊】
shiqian = sgs.General(extension, "时迁", "qun")

shentou = sgs.CreateOneCardViewAsSkill{
	name = "神偷",
	filter_pattern = ".|club|.|hand",
	view_as = function(self, card)
		local new_card = sgs.Sanguosha:cloneCard("snatch", sgs.Card_SuitToBeDecided, -1)
		new_card:addSubcard(card:getId())
		new_card:setSkillName(self:objectName())
		return new_card
	end
}

-- 神行：受到伤害后摸一张牌（触发技，验证 can_trigger/on_cost/on_effect）
shenxing = sgs.CreateTriggerSkill{
	name = "神行",
	events = { sgs.Damaged },
	frequency = sgs.Skill_Frequent,
	on_cost = function(self, event, room, player, data)
		return room:askForSkillInvoke(player, self:objectName())
	end,
	on_effect = function(self, event, room, player, data)
		room:drawCards(player, 1)
		return false
	end
}

shiqian:addSkill(shentou)
shiqian:addSkill(shenxing)

sgs.LoadTranslationTable{
	["moligaloo"] = "太阳神上",
	["shentou"] = "神偷",
	["shenxing"] = "神行",
	[":神偷"] = "你可以将一张梅花手牌当做【顺手牵羊】使用。",
	[":神行"] = "你受到伤害后，可以摸一张牌。",
}

return { extension }
