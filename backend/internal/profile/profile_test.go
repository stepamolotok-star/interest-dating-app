package profile

import "testing"

func TestValidate(t *testing.T) {
	h := func(v int) *int { return &v }
	ok := Fields{
		About:    "Люблю горы",
		Prompts:  []Prompt{{"Идеальные выходные — это…", "Поход и костёр"}},
		HeightCm: h(172), WeightKg: h(64), BodyType: "athletic",
		Habits: map[string]string{"smoking": "no", "wants_kids": "unsure"},
		Diet:   "vegetarian", Religion: "orthodox", ReligionForMatching: true,
	}
	if err := ok.Validate(); err != nil {
		t.Fatal(err)
	}
	bad := map[string]Fields{
		"пустой ответ":        {Prompts: []Prompt{{"Вопрос", " "}}},
		"рост":                {HeightCm: h(300)},
		"телосложение":        {BodyType: "огромное"},
		"религия":             {Religion: "что-то своё"},
		"привычка":            {Habits: map[string]string{"smoking": "много"}},
		"религия для подбора": {ReligionForMatching: true},
		"четыре вопроса":      {Prompts: []Prompt{{"a", "b"}, {"a", "b"}, {"a", "b"}, {"a", "b"}}},
	}
	for name, f := range bad {
		if f.Validate() == nil {
			t.Errorf("%s: ожидалась ошибка", name)
		}
	}
}
