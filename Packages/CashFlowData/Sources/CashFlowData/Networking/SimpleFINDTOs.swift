import Foundation

struct SimpleFINAccountSetDTO: Decodable, Sendable {
    let errors: [String]?
    let errlist: [SimpleFINErrorDTO]?
    let connections: [SimpleFINConnectionDTO]?
    let accounts: [SimpleFINAccountDTO]

    var displayMessages: [String] {
        if let errlist, !errlist.isEmpty {
            return errlist.map(\.msg)
        }
        return errors ?? []
    }
}

struct SimpleFINErrorDTO: Decodable, Sendable {
    let code: String
    let msg: String
    let connID: String?
    let accountID: String?

    enum CodingKeys: String, CodingKey {
        case code, msg
        case connID = "conn_id"
        case accountID = "account_id"
    }
}

struct SimpleFINConnectionDTO: Decodable, Sendable {
    let connID: String
    let name: String
    let orgID: String?
    let orgName: String?
    let orgURL: String?
    let sfinURL: String?

    init(
        connID: String,
        name: String,
        orgID: String? = nil,
        orgName: String? = nil,
        orgURL: String? = nil,
        sfinURL: String? = nil
    ) {
        self.connID = connID
        self.name = name
        self.orgID = orgID
        self.orgName = orgName
        self.orgURL = orgURL
        self.sfinURL = sfinURL
    }

    enum CodingKeys: String, CodingKey {
        case name
        case connID = "conn_id"
        case orgID = "org_id"
        case orgName = "org_name"
        case orgURL = "org_url"
        case sfinURLHyphen = "sfin-url"
        case sfinURLUnderscore = "sfin_url"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        connID = try container.decode(String.self, forKey: .connID)
        name = try container.decode(String.self, forKey: .name)
        orgID = try container.decodeIfPresent(String.self, forKey: .orgID)
        orgName = try container.decodeIfPresent(String.self, forKey: .orgName)
        orgURL = try container.decodeIfPresent(String.self, forKey: .orgURL)
        sfinURL = try container.decodeIfPresent(String.self, forKey: .sfinURLUnderscore)
            ?? container.decodeIfPresent(String.self, forKey: .sfinURLHyphen)
    }
}

struct SimpleFINAccountDTO: Decodable, Sendable {
    let org: SimpleFINOrgDTO?
    let id: String
    let name: String
    let currency: String
    let balance: String
    let availableBalance: String?
    let balanceDate: Int
    let transactions: [SimpleFINTransactionDTO]?
    let connID: String?
    let connName: String?

    enum CodingKeys: String, CodingKey {
        case org, id, name, currency, balance, transactions
        case availableBalance = "available-balance"
        case balanceDate = "balance-date"
        case connID = "conn_id"
        case connName = "conn_name"
    }
}

struct SimpleFINOrgDTO: Decodable, Sendable {
    let domain: String?
    let name: String?
    let sfinURL: String?

    enum CodingKeys: String, CodingKey {
        case domain, name
        case sfinURL = "sfin-url"
    }
}

struct SimpleFINTransactionDTO: Decodable, Sendable {
    let id: String
    let posted: Int
    let amount: String
    let description: String
    let pending: Bool?
}

struct SimpleFINInfoDTO: Decodable, Sendable {
    let versions: [String]
}
