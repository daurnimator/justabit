describe("mime", function()
	local json = require "justabit.json"
	local mime = require "justabit.mime"
	local header_forms = mime.header_forms

	it("Addresses", function()
		assert.same(json.decode('[{"email":"a@b.com","name":null}]'), header_forms.Addresses("a@b.com"))
		assert.same(json.decode('[{"email":"a@b.com","name":"foo"}]'), header_forms.Addresses("foo <a@b.com>"))
	end)

	it("GroupedAddresses", function()
		assert.same(
			json.decode([=[
				[
					{"name":null, "addresses":["james@example.com"]},
					{"name":"Friends", "addresses":[
						{"email":"jane@example.com","name":null},
						{"email":"john@example.com","name":"John Smîth"}
					]}
				]
			]=]),
		   header_forms.GroupedAddresses([["  James Smythe" <james@example.com>, Friends:jane@example.com, =?UTF-8?Q?John_Sm=C3=AEth?=<john@example.com>;]])
		)
	end)
end)
