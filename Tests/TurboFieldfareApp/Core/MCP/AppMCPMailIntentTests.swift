import Testing
@testable import TurboFieldfareAppCore

@Suite struct AppMCPMailIntentTests {
    @Test func periodsFromOrdinaryRequests() throws {
        for (text, period) in [
            ("Разбери почту за сегодня", "today"), ("Какие письма пришли сегодня?", "today"),
            ("Что важного в письмах за неделю?", "this_week"), ("Покажи почту за текущую неделю", "this_week"),
            ("Сводка вчерашней почты", "yesterday"), ("Проанализируй письма за вчера", "yesterday"),
            ("Summarize my email this week", "this_week"), ("Check my inbox today", "today"),
            ("Разбери почту", "today")
        ] {
            let intent = try #require(try AppMCPMailIntent.resolve(text))
            #expect(intent.period == period, "\(text)")
            #expect(intent.folder == "Inbox")
        }
    }

    @Test func referencesAndNonMailRequestsDoNotAccessMailbox() throws {
        for text in ["Составь план на сегодня", "Что такое MCP для почты?", "Как подключить почту за неделю?",
                     "Переведи: «разбери почту за сегодня»", "Напиши письмо про прошлую неделю",
                     "Проанализируй приложенные письма за сегодня", "Не читай почту за сегодня",
                     "Do not read my email today", "Напиши код: ```почта за сегодня```", "А за неделю?",
                     "Почти закончил задачи за неделю", "Письменный план на сегодня", "Show exchange rate today",
                     "Economic outlook this week", "Входящие запросы за сегодня"] {
            #expect(try AppMCPMailIntent.resolve(text) == nil, "\(text)")
        }
    }

    @Test func unsupportedDatesAndWriteRequestsFailBeforeConnection() {
        for text in ["Почта за прошлую неделю", "Почта за месяц", "Покажи почту за последние 7 дней",
                     "Письма с 01.09 по 04.09", "Почта сегодня и вчера", "Удали письма за сегодня",
                     "Пометь почту за неделю прочитанной", "Send my emails today"] {
            #expect(throws: AppMCPError.self) { try AppMCPMailIntent.resolve(text) }
        }
    }

    @Test func followupAndFolderSelection() throws {
        #expect(try AppMCPMailIntent.resolve("А за неделю?", previousUserPrompt: "Разбери почту за сегодня")?.period == "this_week")
        #expect(try AppMCPMailIntent.resolve("А за неделю?", previousUserPrompt: "Составь план на сегодня") == nil)
        #expect(try AppMCPMailIntent.resolve("Составь план на сегодня", previousUserPrompt: "Разбери почту") == nil)
        #expect(try AppMCPMailIntent.resolve("Письма за неделю из папки «Проект»")?.folder == "Проект")
        #expect(try AppMCPMailIntent.resolve("Покажи отправленные письма за вчера")?.folder == "Sent")
        #expect(throws: AppMCPError.self) { try AppMCPMailIntent.resolve("Письма за неделю во всех папках") }
    }
}
